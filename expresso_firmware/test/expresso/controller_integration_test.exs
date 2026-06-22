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

    config_path =
      Path.join(System.tmp_dir!(), "integration_test_#{System.unique_integer()}.json")

    previous_config_path = Application.get_env(:expresso_firmware, :config_path)
    Application.put_env(:expresso_firmware, :config_path, config_path)

    on_exit(fn ->
      if is_nil(previous_heater) do
        Application.delete_env(:expresso_firmware, :heater_module)
      else
        Application.put_env(:expresso_firmware, :heater_module, previous_heater)
      end

      if is_nil(previous_config_path) do
        Application.delete_env(:expresso_firmware, :config_path)
      else
        Application.put_env(:expresso_firmware, :config_path, previous_config_path)
      end

      File.rm(config_path)
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
      brew_kp: 16.0,
      brew_ki: 2.5,
      brew_kd: 16.0,
      steam_kp: 0.75,
      steam_ki: 0.0125,
      steam_kd: 0.0,
      steam_lambda_seconds: 15.0,
      brew_cooling_compensation_c: 2.7,
      brew_kp_multiplier: 1.2,
      autotune_enabled: true,
      lambda_seconds: 10.0,
      tau_seconds: 45.0,
      process_gain: 1.0,
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
      initialized: false,
      history: :queue.new(),
      history_count: 0
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

  describe "steam mode gain switching" do
    test "steam switch ON applies steam gains and setpoint" do
      state = base_state(mode: :pid, initialized: true)

      {:noreply, steam_state} = Controller.handle_info({:circuits_gpio, 17, 0, 0}, state)

      assert steam_state.kp == state.steam_kp
      assert steam_state.ki == state.steam_ki
      assert steam_state.kd == state.steam_kd
      assert steam_state.setpoint == state.steam_setpoint
      assert steam_state.steam_switch_state == :on
      assert steam_state.initialized == false
    end

    test "steam switch OFF restores brew gains and setpoint" do
      state =
        base_state(
          mode: :pid,
          steam_switch_state: :on,
          setpoint: 155.0,
          kp: 0.75,
          ki: 0.0125,
          kd: 0.0,
          initialized: true
        )

      {:noreply, restored_state} = Controller.handle_info({:circuits_gpio, 17, 0, 1}, state)

      assert restored_state.kp == state.brew_kp
      assert restored_state.ki == state.brew_ki
      assert restored_state.kd == state.brew_kd
      assert restored_state.setpoint == state.brew_setpoint
      assert restored_state.steam_switch_state == :off
      assert restored_state.initialized == false
    end

    test "brew switch ON after steam OFF uses brew_kp anchor (not steam gains)" do
      state = base_state(mode: :pid, steam_switch_state: :off)

      {:noreply, brew_state} = Controller.handle_info({:circuits_gpio, 27, 0, 0}, state)

      assert_in_delta brew_state.kp, state.brew_kp * state.brew_kp_multiplier, 0.01
      refute brew_state.kp == state.steam_kp
    end
  end

  describe "autotune toggle" do
    test "autotune_lambda is no-op when autotune disabled" do
      state = base_state(autotune_enabled: false, brew_kp: 1.5, brew_ki: 0.05)

      {:reply, result, new_state} =
        Controller.handle_call({:autotune_lambda, 8.0}, nil, state)

      assert result == {:error, :autotune_disabled}
      assert new_state.brew_kp == 1.5
      assert new_state.brew_ki == 0.05
    end

    test "set_config can disable autotune and it persists in state" do
      state = base_state(autotune_enabled: true)

      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [autotune_enabled: false]}, nil, state)

      assert new_state.autotune_enabled == false
    end
  end

  describe "set_config brew anchor sync" do
    test "manual kp change through set_config updates brew_kp anchor (autotune off)" do
      state = base_state(autotune_enabled: false, kp: 0.82, brew_kp: 0.82)

      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [kp: 1.5]}, nil, state)

      assert new_state.kp == 1.5
      assert new_state.brew_kp == 1.5
    end

    test "brew boost after manual kp uses new manual value as anchor (autotune off)" do
      state = base_state(autotune_enabled: false, kp: 1.5, brew_kp: 1.5, brew_switch_state: :off, mode: :pid)

      {:reply, updated_state, updated_state} =
        Controller.handle_call({:set_config, [kp: 2.0]}, nil, state)

      {:noreply, brew_state} =
        Controller.handle_info({:circuits_gpio, 27, 0, 0}, updated_state)

      assert_in_delta brew_state.kp, 2.0 * updated_state.brew_kp_multiplier, 0.01
    end

    test "set_config with gain fields is ignored when autotune is enabled" do
      state = base_state(autotune_enabled: true, kp: 0.82, brew_kp: 0.82)

      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [kp: 1.5]}, nil, state)

      assert new_state.kp == 0.82
      assert new_state.brew_kp == 0.82
    end
  end

  describe "history recording" do
    test "get_history returns empty list when no samples recorded" do
      state = base_state(mode: :disabled)

      {:reply, samples, _} = Controller.handle_call(:get_history, nil, state)

      assert samples == []
    end

    test "multi-cycle PID run accumulates samples in history" do
      state = base_state(mode: :pid, initialized: true)

      {:noreply, s1} = Controller.handle_info(:control_loop, state)
      {:noreply, s2} = Controller.handle_info(:control_loop, s1)
      {:noreply, s3} = Controller.handle_info(:control_loop, s2)

      assert s3.history_count == 3
      {:reply, samples, _} = Controller.handle_call(:get_history, nil, s3)
      assert length(samples) == 3
      [a, b, c] = samples
      assert a.t <= b.t
      assert b.t <= c.t
    end
  end
end
