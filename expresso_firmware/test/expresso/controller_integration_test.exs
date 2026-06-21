defmodule ExpressoFirmware.ControllerIntegrationTest do
  use ExUnit.Case

  alias ExpressoFirmware.Controller

  defmodule TestHeater do
    def set_output(_output, _max_output), do: :ok
    def get_reading(), do: 95.0
  end

  setup do
    previous_heater = Application.get_env(:expresso_firmware, :heater_module)
    Application.put_env(:expresso_firmware, :heater_module, TestHeater)

    on_exit(fn ->
      if is_nil(previous_heater) do
        Application.delete_env(:expresso_firmware, :heater_module)
      else
        Application.put_env(:expresso_firmware, :heater_module, previous_heater)
      end
    end)
  end

  # Helper to build a valid State struct with all required fields
  defp base_state(overrides \\ []) do
    defaults = %Controller.State{
      mode: :disabled,
      brew_switch_state: :off,
      steam_switch_state: :off,
      brew_setpoint: 93.5,
      setpoint: 93.5,
      steam_setpoint: 155.0,
      kp: 16.0,
      ki: 2.5,
      kd: 16.0,
      cycle_ms: 1000,
      max_integral: 20.0,
      min_output: 0,
      max_output: 100,
      brew_pwm_output: 30.0,
      brew_switch_ref: nil,
      steam_switch_ref: nil,
      reading: 20.0,
      last_error: 0,
      last_output: 0,
      error_sum: 0.0,
      initialized: false
    }
    struct(defaults, overrides)
  end

  describe "lambda tuning gains applied on init" do
    test "default lambda gains are consistent with formula" do
      {kp, ki, kd} = Controller.calculate_lambda_gains()
      # tau=45, lambda=10, pg=1: kp=45/55, ki=(45/55)/55
      assert_in_delta(kp, 45.0 / 55.0, 0.01)
      assert_in_delta(ki, (45.0 / 55.0) / 55.0, 0.001)
      assert kd == 0
    end

    test "faster lambda (8s) produces more aggressive gains than default (10s)" do
      {kp_default, ki_default, _} = Controller.calculate_lambda_gains(45.0, 10.0, 1.0)
      {kp_fast, ki_fast, _} = Controller.calculate_lambda_gains(45.0, 8.0, 1.0)

      assert kp_fast > kp_default
      assert ki_fast > ki_default
    end
  end

  describe "mode transitions with initialization" do
    test "enable_pid resets initialized flag" do
      state = base_state(mode: :disabled, initialized: true)
      {:noreply, new_state} = Controller.handle_cast(:enable_pid, state)
      assert new_state.initialized == false
    end

    test "disable_pid sets mode to :disabled" do
      state = base_state(mode: :pid, initialized: true)
      {:noreply, new_state} = Controller.handle_cast(:disable_pid, state)
      assert new_state.mode == :disabled
    end

    test "steam switch ON changes setpoint and resets initialized" do
      state = base_state(mode: :pid, initialized: true)
      # steam_switch_pin is 17 (from config/config.exs)
      {:noreply, new_state} = Controller.handle_info({:circuits_gpio, 17, 0, 0}, state)
      assert new_state.setpoint == state.steam_setpoint
      assert new_state.initialized == false
    end

    test "steam switch OFF restores brew setpoint" do
      state = base_state(mode: :pid, setpoint: 155.0, initialized: true)
      # steam_switch_pin is 17 (from config/config.exs)
      {:noreply, new_state} = Controller.handle_info({:circuits_gpio, 17, 0, 1}, state)
      assert new_state.setpoint == state.brew_setpoint
      assert new_state.initialized == false
    end
  end

  describe "brew phase full cycle simulation" do
    test "brew ON → multi-cycle PID → brew OFF maintains state consistency" do
      # Start: normal PID at brew setpoint
      initial_state = base_state(mode: :pid, initialized: true)

      # Brew switch ON (pin 27, value 0 = switch closed/active with pull-up)
      {:noreply, brew_state} = Controller.handle_info({:circuits_gpio, 27, 0, 0}, initial_state)
      assert brew_state.mode == :pid
      assert brew_state.setpoint > initial_state.setpoint
      assert brew_state.error_sum == 0.0
      assert brew_state.initialized == false

      # First PID cycle after brew ON (initializes last_error)
      {:noreply, init_state} = Controller.handle_info(:control_loop, brew_state)
      assert init_state.initialized == true

      # Second PID cycle (actual PID calculation)
      {:noreply, running_state} = Controller.handle_info(:control_loop, init_state)
      assert running_state.last_output >= 0
      assert running_state.last_output <= 100

      # Brew switch OFF (pin 27, value 1 = switch open with pull-up)
      {:noreply, post_brew_state} = Controller.handle_info({:circuits_gpio, 27, 0, 1}, running_state)
      assert post_brew_state.setpoint == initial_state.brew_setpoint
      assert post_brew_state.error_sum == 0.0
      assert post_brew_state.initialized == false
    end

    test "integral does not windup during full-heat phase" do
      # State: temperature far below setpoint, system saturating at max_output.
      # TestHeater.get_reading() returns 95.0, so we set a high setpoint (150°C)
      # to ensure error is large and output saturates at max_output.
      # error = 150 - 95 = 55, unclamped_output = 16*55 + 2.5*20 + 16*(55-33.5) >> 100
      state = base_state(
        mode: :pid,
        initialized: true,
        setpoint: 150.0,
        reading: 60.0,
        last_error: 33.5,
        error_sum: 20.0,  # near max_integral
        kp: 16.0,
        ki: 2.5,
        kd: 16.0,
        max_integral: 20.0,
        max_output: 100
      )

      {:noreply, new_state} = Controller.handle_info(:control_loop, state)

      # Output should be clamped to max
      assert new_state.last_output == 100
      # Integral should be frozen (not increase beyond current value) due to anti-windup
      assert new_state.error_sum == state.error_sum
    end
  end
end
