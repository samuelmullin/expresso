defmodule ExpressoFirmware.ControllerTest do
  use ExUnit.Case

  alias ExpressoFirmware.Controller

  defmodule TestHeater do
    def set_output(output, max_output) do
      send(ExpressoFirmware.ControllerTest, {:set_output, output, max_output})
      :ok
    end

    def get_reading() do
      95.0
    end
  end

  setup do
    previous_heater = Application.get_env(:expresso_firmware, :heater_module)
    Application.put_env(:expresso_firmware, :heater_module, TestHeater)
    Process.register(self(), __MODULE__)

    on_exit(fn ->
      if is_nil(previous_heater) do
        Application.delete_env(:expresso_firmware, :heater_module)
      else
        Application.put_env(:expresso_firmware, :heater_module, previous_heater)
      end

      if Process.whereis(__MODULE__) == self() do
        Process.unregister(__MODULE__)
      end
    end)
  end

  test "defaults brew switch PWM output to 30 percent" do
    assert %Controller.State{brew_pwm_output: 30.0} = %Controller.State{}
  end

  test "is supervised as a permanent worker" do
    assert %{restart: :permanent, type: :worker} = Controller.child_spec([])
  end

  test "forces heater output off when the controller terminates" do
    state = %Controller.State{max_output: 100}

    assert :ok = Controller.terminate(:sensor_failure, state)
    assert_receive {:set_output, 0, 100}
  end

  describe "derivative kick prevention" do
    @tag :derivative_kick_prevention
    test "first PID cycle does not apply derivative term" do
      # Simulate: system at 95°C (real), setpoint 95°C, reading initialized to 20°C
      state = %Controller.State{
        mode: :pid,
        initialized: false,
        reading: 20.0,
        last_error: 0,
        last_output: 0,
        error_sum: 0.0,
        setpoint: 95.0,
        kp: 16.0,
        ki: 2.5,
        kd: 16.0,
        cycle_ms: 1000,
        max_integral: 20.0,
        min_output: 0,
        max_output: 100
      }

      # Send first control loop — should initialize without applying PID
      {:noreply, new_state} = Controller.handle_info(:control_loop, state)

      # After first cycle:
      # - initialized should be true
      # - last_error should be set from real reading (not 0)
      # - no heater output yet (next cycle applies PID)
      assert new_state.initialized == true
      assert new_state.last_error == 0.0
      # On second cycle, error_change will be (95 - 95) - (95 - 95) = 0
      # Thus no derivative spike
    end
  end

  describe "anti-windup integration" do
    @tag :anti_windup
    test "integral freezes when output saturates at max" do
      state = %Controller.State{
        mode: :pid,
        initialized: true,
        reading: 60.0,
        last_error: 35.0,  # error with setpoint 130
        last_output: 0,
        error_sum: 20.0,   # already near max_integral
        setpoint: 130.0,   # reading from get_reading() will be 95, so error = 130 - 95 = 35
        kp: 16.0,
        ki: 2.5,
        kd: 16.0,
        cycle_ms: 1000,
        max_integral: 20.0,
        min_output: 0,
        max_output: 100
      }

      # With Ki=2.5 and error_sum=20.0, ki contribution = 50, which when added to kp term
      # will exceed max_output=100, causing saturation

      {:noreply, new_state} = Controller.handle_info(:control_loop, state)

      # When output is saturated, error_sum should NOT increase further
      # (it should remain frozen at the previous value during saturation)
      assert new_state.error_sum == state.error_sum
      assert new_state.last_output == 100  # output clamped to max
    end

    @tag :anti_windup
    test "integral resumes accumulating when output leaves saturation" do
      state = %Controller.State{
        mode: :pid,
        initialized: true,
        reading: 94.0,   # getting close to setpoint
        last_error: 1.0,
        last_output: 100,
        error_sum: 20.0,  # frozen during previous saturation
        setpoint: 96.0,   # reading from get_reading() will be 95, so error = 96 - 95 = 1
        kp: 16.0,
        ki: 2.5,
        kd: 16.0,
        cycle_ms: 1000,
        max_integral: 25.0,
        min_output: 0,
        max_output: 100
      }

      {:noreply, new_state} = Controller.handle_info(:control_loop, state)

      # Error is now small (1°C), so output won't saturate
      # error_sum should resume accumulating
      expected_error_sum = 20.0 + 1.0  # frozen value + new error
      assert new_state.error_sum == expected_error_sum
    end
  end
end
