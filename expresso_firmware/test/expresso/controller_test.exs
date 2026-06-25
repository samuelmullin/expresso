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

  test "init applies lambda gains when autotune enabled (no file)" do
    # With no config file, autotune=true (default), gains are calculated
    assert {:ok, state} = Controller.init([])
    # Lambda gains applied: kp ≈ 45/55 ≈ 0.818
    assert_in_delta state.kp, 45.0 / 55.0, 0.01
    assert_in_delta state.brew_kp, 45.0 / 55.0, 0.01
    # Active kp = brew_kp
    assert state.kp == state.brew_kp
  end

  test "init uses brew_kp as active kp when autotune is disabled" do
    assert {:ok, state} = Controller.init(autotune_enabled: false, brew_kp: 12.0, brew_ki: 0.5, brew_kd: 1.25)
    assert state.kp == 12.0
    assert state.brew_kp == 12.0
    assert state.ki == 0.5
    assert state.kd == 1.25
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
      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)

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

  describe "brew phase feedforward compensation" do
    @tag :brew_phase
    test "enable_pid while brew switch is on applies feedforward PID compensation" do
      state = %Controller.State{
        mode: :disabled,
        brew_switch_state: :on,
        brew_setpoint: 93.5,
        setpoint: 93.5,
        kp: 16.0,
        brew_kp: 16.0,
        brew_ki: 2.5,
        brew_kd: 16.0,
        error_sum: 10.0,
        last_error: 2.0,
        initialized: true
      }

      {:noreply, new_state} = Controller.handle_cast(:enable_pid, state)

      assert new_state.mode == :pid
      assert_in_delta(new_state.setpoint, 93.5 + 2.7, 0.05)
      assert_in_delta(new_state.kp, 16.0 * 1.2, 0.01)
      assert new_state.error_sum == 0.0
      assert new_state.last_error == 0
      assert new_state.initialized == false
    end

    @tag :brew_phase
    test "brew switch ON boosts setpoint by expected cooling compensation" do
      state = %Controller.State{
        mode: :pid,
        brew_switch_state: :off,
        brew_setpoint: 93.5,
        setpoint: 93.5,
        kp: 16.0,
        brew_kp: 16.0,
        brew_ki: 2.5,
        brew_kd: 16.0,
        ki: 2.5,
        kd: 16.0,
        error_sum: 0.0,
        last_error: 0,
        reading: 93.5,
        brew_switch_ref: nil,
        steam_switch_ref: nil,
        initialized: false
      }

      # @brew_switch_pin = 27, value 0 = ON
      send_message = {:circuits_gpio, 27, 0, 0}
      {:noreply, new_state} = Controller.handle_info(send_message, state)

      # Expected: setpoint raised by ~2.7°C (0.1°C/sec * 27 sec)
      # 93.5 + 2.7 = 96.2°C
      expected_setpoint = 93.5 + 2.7
      assert_in_delta(new_state.setpoint, expected_setpoint, 0.05)

      # Mode should be :pid (not :pwm)
      assert new_state.mode == :pid

      # Kp should be boosted by 1.2× from brew_kp (not from current kp, to prevent compounding)
      assert_in_delta(new_state.kp, state.brew_kp * 1.2, 0.01)

      # Integral should be reset to prevent windup
      assert new_state.error_sum == 0.0
    end

    @tag :brew_phase
    test "brew switch OFF restores normal setpoint and Kp" do
      state = %Controller.State{
        mode: :pid,
        brew_switch_state: :on,
        brew_setpoint: 93.5,
        # boosted during brew
        setpoint: 96.2,
        # boosted
        kp: 16.0 * 1.2,
        brew_kp: 16.0,
        brew_ki: 2.5,
        brew_kd: 16.0,
        ki: 2.5,
        kd: 16.0,
        error_sum: 0.0,
        last_error: 0,
        reading: 96.0,
        brew_switch_ref: nil,
        steam_switch_ref: nil,
        initialized: true
      }

      # @brew_switch_pin = 27, value 1 = OFF
      send_message = {:circuits_gpio, 27, 0, 1}
      {:noreply, new_state} = Controller.handle_info(send_message, state)

      # Setpoint should return to brew setpoint (no more compensation)
      assert new_state.setpoint == 93.5

      # Kp should be restored to brew_kp (not divided, to prevent permanent drift on bounce)
      assert_in_delta(new_state.kp, state.brew_kp, 0.01)

      # Mode should remain :pid
      assert new_state.mode == :pid

      # Integral reset on transition
      assert new_state.error_sum == 0.0
    end
  end

  describe "lambda tuning gain calculation" do
    test "calculate_lambda_gains returns expected gains for default parameters" do
      tau = 45.0
      lambda = 10.0
      process_gain = 1.0

      {kp, ki, kd} = Controller.calculate_lambda_gains(tau, lambda, process_gain)

      # kp = (1/1.0) * (45 / (10 + 45)) = 45/55 ≈ 0.818
      # ki = 0.818 / (45 + 10) = 0.818 / 55 ≈ 0.0149
      # kd = 0
      assert_in_delta(kp, 45.0 / 55.0, 0.01)
      assert_in_delta(ki, 45.0 / 55.0 / 55.0, 0.001)
      assert kd == 0
    end

    test "faster lambda produces higher Kp" do
      tau = 45.0
      process_gain = 1.0

      {kp_slow, _, _} = Controller.calculate_lambda_gains(tau, 15.0, process_gain)
      {kp_fast, _, _} = Controller.calculate_lambda_gains(tau, 5.0, process_gain)

      assert kp_fast > kp_slow
    end
  end

  describe "anti-windup integration" do
    @tag :anti_windup
    test "integral freezes when output saturates at max" do
      state = %Controller.State{
        mode: :pid,
        initialized: true,
        reading: 60.0,
        # error with setpoint 130
        last_error: 35.0,
        last_output: 0,
        # already near max_integral
        error_sum: 20.0,
        # reading from get_reading() will be 95, so error = 130 - 95 = 35
        setpoint: 130.0,
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

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)

      # When output is saturated, error_sum should NOT increase further
      # (it should remain frozen at the previous value during saturation)
      assert new_state.error_sum == state.error_sum
      # output clamped to max
      assert new_state.last_output == 100
    end

    @tag :anti_windup
    test "integral resumes accumulating when output leaves saturation" do
      state = %Controller.State{
        mode: :pid,
        initialized: true,
        # getting close to setpoint
        reading: 94.0,
        last_error: 1.0,
        last_output: 100,
        # frozen during previous saturation
        error_sum: 20.0,
        # reading from get_reading() will be 95, so error = 96 - 95 = 1
        setpoint: 96.0,
        kp: 16.0,
        ki: 2.5,
        kd: 16.0,
        cycle_ms: 1000,
        max_integral: 25.0,
        min_output: 0,
        max_output: 100
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)

      # Error is now small (1°C), so output won't saturate
      # error_sum should resume accumulating
      # frozen value + new error
      expected_error_sum = 20.0 + 1.0
      assert new_state.error_sum == expected_error_sum
    end
  end

  describe "history recording" do
    test "initialized PID tick adds a sample to history" do
      state = %Controller.State{
        mode: :pid,
        initialized: true,
        setpoint: 93.5,
        kp: 16.0,
        ki: 2.5,
        kd: 16.0,
        max_integral: 20.0,
        min_output: 0,
        max_output: 100,
        last_error: 0,
        error_sum: 0.0,
        history: :queue.new(),
        history_count: 0,
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)

      assert new_state.history_count == 1
      assert [sample] = :queue.to_list(new_state.history)
      assert sample.mode == :pid
      assert is_integer(sample.t)
      assert is_float(sample.temp)
      assert sample.sp == 93.5
      assert sample.out == new_state.last_output
    end

    test "disabled mode tick does not add a sample" do
      state = %Controller.State{
        mode: :disabled,
        history: :queue.new(),
        history_count: 0,
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)

      assert new_state.history_count == 0
      assert :queue.to_list(new_state.history) == []
    end

    test "uninitialized PID tick does not add a sample" do
      state = %Controller.State{
        mode: :pid,
        initialized: false,
        setpoint: 93.5,
        history: :queue.new(),
        history_count: 0,
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)

      assert new_state.history_count == 0
      assert :queue.to_list(new_state.history) == []
    end

    test "ring buffer wraps at history max and drops oldest sample" do
      history_max = 600

      full_q =
        Enum.reduce(1..history_max, :queue.new(), fn i, q ->
          :queue.in(%{t: i, temp: 90.0, sp: 93.5, out: 50, mode: :pid}, q)
        end)

      state = %Controller.State{
        mode: :pid,
        initialized: true,
        setpoint: 93.5,
        kp: 16.0,
        ki: 2.5,
        kd: 16.0,
        max_integral: 20.0,
        min_output: 0,
        max_output: 100,
        last_error: 0,
        error_sum: 0.0,
        history: full_q,
        history_count: history_max,
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)

      assert new_state.history_count == history_max
      samples = :queue.to_list(new_state.history)
      assert length(samples) == history_max
      assert hd(samples).t == 2
    end

    test "get_history returns oldest-first list" do
      q =
        :queue.in(
          %{t: 1, temp: 90.0, sp: 93.5, out: 50, mode: :pid},
          :queue.in(%{t: 0, temp: 89.0, sp: 93.5, out: 55, mode: :pid}, :queue.new())
        )

      state = %Controller.State{history: q, history_count: 2}

      {:reply, samples, _} = Controller.handle_call(:get_history, nil, state)

      assert [%{t: 0}, %{t: 1}] = samples
    end
  end

  describe "autotune toggle" do
    test "autotune_lambda returns :autotune_disabled when autotune is off" do
      state = %Controller.State{autotune_enabled: false, brew_kp: 1.0, brew_ki: 0.01, brew_kd: 0.0}
      assert {:reply, {:error, :autotune_disabled}, ^state} =
               Controller.handle_call({:autotune_lambda, 10.0}, nil, state)
    end

    test "autotune_lambda updates both brew and steam gains when autotune is on" do
      state = %Controller.State{
        autotune_enabled: true,
        tau_seconds: 45.0,
        process_gain: 1.0,
        steam_lambda_seconds: 15.0,
        steam_switch_state: :off,
        brew_kp: 0.5,
        brew_ki: 0.01,
        brew_kd: 0.0,
        steam_kp: 0.4,
        steam_ki: 0.008,
        steam_kd: 0.0,
        kp: 0.5,
        ki: 0.01,
        kd: 0.0
      }

      {:reply, {:ok, {new_kp, new_ki, new_kd}}, new_state} =
        Controller.handle_call({:autotune_lambda, 10.0}, nil, state)

      # Brew gains: tau=45, lambda=10 → kp = 45/55 ≈ 0.818
      assert_in_delta new_kp, 45.0 / 55.0, 0.01
      assert_in_delta new_ki, 45.0 / 55.0 / 55.0, 0.001
      assert new_kd == 0

      # Brew gains written to brew_kp/ki/kd
      assert_in_delta new_state.brew_kp, 45.0 / 55.0, 0.01
      assert_in_delta new_state.brew_ki, 45.0 / 55.0 / 55.0, 0.001

      # Steam gains: tau=45, lambda=15 → kp = 45/60 = 0.75
      assert_in_delta new_state.steam_kp, 45.0 / 60.0, 0.01
      assert_in_delta new_state.steam_ki, 45.0 / 60.0 / 60.0, 0.001

      # Active kp/ki/kd = brew gains (steam switch is off)
      assert_in_delta new_state.kp, 45.0 / 55.0, 0.01
    end

    test "autotune_lambda applies steam gains as active when steam switch is on" do
      state = %Controller.State{
        autotune_enabled: true,
        tau_seconds: 45.0,
        process_gain: 1.0,
        steam_lambda_seconds: 15.0,
        steam_switch_state: :on,
        brew_kp: 0.5, brew_ki: 0.01, brew_kd: 0.0,
        steam_kp: 0.4, steam_ki: 0.008, steam_kd: 0.0,
        kp: 0.4, ki: 0.008, kd: 0.0
      }

      {:reply, {:ok, _}, new_state} =
        Controller.handle_call({:autotune_lambda, 10.0}, nil, state)

      # Active gains = steam gains (steam switch is on)
      assert_in_delta new_state.kp, 45.0 / 60.0, 0.01
      assert_in_delta new_state.ki, 45.0 / 60.0 / 60.0, 0.001
    end
  end

  describe "set_config brew anchor sync" do
    test "set_config syncs brew_kp when kp is updated (autotune off)" do
      state = %Controller.State{autotune_enabled: false, kp: 0.82, brew_kp: 0.82, brew_ki: 0.015, brew_kd: 0.0}
      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [kp: 1.5]}, nil, state)
      assert new_state.kp == 1.5
      assert new_state.brew_kp == 1.5
    end

    test "set_config syncs brew_ki when ki is updated (autotune off)" do
      state = %Controller.State{autotune_enabled: false, ki: 0.015, brew_ki: 0.015}
      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [ki: 0.05]}, nil, state)
      assert new_state.ki == 0.05
      assert new_state.brew_ki == 0.05
    end

    test "set_config syncs brew_kd when kd is updated (autotune off)" do
      state = %Controller.State{autotune_enabled: false, kd: 0.0, brew_kd: 0.0}
      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [kd: 2.0]}, nil, state)
      assert new_state.kd == 2.0
      assert new_state.brew_kd == 2.0
    end

    test "set_config does not change brew_kp when only non-gain keys change" do
      state = %Controller.State{kp: 0.82, brew_kp: 0.82, brew_setpoint: 93.5}
      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [brew_setpoint: 94.0]}, nil, state)
      assert new_state.brew_kp == 0.82
      assert new_state.brew_setpoint == 94.0
    end

    test "set_config ignores gain fields when autotune is enabled" do
      state = %Controller.State{autotune_enabled: true, kp: 0.82, brew_kp: 0.82}
      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [kp: 1.5, brew_setpoint: 94.0]}, nil, state)
      # Gain blocked — kp and brew_kp unchanged
      assert new_state.kp == 0.82
      assert new_state.brew_kp == 0.82
      # Non-gain field still applied
      assert new_state.brew_setpoint == 94.0
    end

    test "set_config enabling autotune in the same call blocks gains from that same call" do
      state = %Controller.State{autotune_enabled: false, kp: 0.82, brew_kp: 0.82}
      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [autotune_enabled: true, kp: 5.0]}, nil, state)
      # autotune enabled
      assert new_state.autotune_enabled == true
      # kp not overridden — effective autotune was true for this call
      assert new_state.kp == 0.82
    end

    test "set_config disabling autotune and setting gains in one call applies both" do
      state = %Controller.State{autotune_enabled: true, kp: 0.82, brew_kp: 0.82, brew_ki: 0.015, brew_kd: 0.0}
      {:reply, new_state, new_state} =
        Controller.handle_call({:set_config, [autotune_enabled: false, kp: 1.5]}, nil, state)
      # autotune disabled
      assert new_state.autotune_enabled == false
      # gain applied because effective autotune is now false
      assert new_state.kp == 1.5
      assert new_state.brew_kp == 1.5
    end
  end

  describe "sensor failure detection" do
    defmodule BadReadingHeater do
      def set_output(output, max_output), do: send(ExpressoFirmware.ControllerTest, {:set_output, output, max_output})
      def get_reading(), do: 999.0
    end

    test "out-of-range reading increments sensor_failure_count" do
      Application.put_env(:expresso_firmware, :heater_module, BadReadingHeater)

      state = %Controller.State{
        mode: :pid,
        initialized: true,
        setpoint: 93.5,
        reading: 93.5,
        kp: 1.0, ki: 0.01, kd: 0.0,
        error_sum: 0.0, last_error: 0,
        cycle_ms: 1000, max_integral: 20.0, min_output: 0, max_output: 100,
        sensor_failure_count: 0
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert new_state.sensor_failure_count == 1
      assert new_state.mode == :pid
    end

    test "three consecutive bad readings disables heater" do
      Application.put_env(:expresso_firmware, :heater_module, BadReadingHeater)

      state = %Controller.State{
        mode: :pid,
        initialized: true,
        setpoint: 93.5,
        reading: 93.5,
        kp: 1.0, ki: 0.01, kd: 0.0,
        error_sum: 0.0, last_error: 0,
        cycle_ms: 1000, max_integral: 20.0, min_output: 0, max_output: 100,
        sensor_failure_count: 2
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert new_state.mode == :disabled
      assert new_state.sensor_failure_count == 3
      assert_receive {:set_output, 0, 100}
    end

    test "valid reading resets sensor_failure_count" do
      state = %Controller.State{
        mode: :pid,
        initialized: true,
        setpoint: 93.5,
        reading: 93.5,
        kp: 1.0, ki: 0.01, kd: 0.0,
        error_sum: 0.0, last_error: 0,
        cycle_ms: 1000, max_integral: 20.0, min_output: 0, max_output: 100,
        sensor_failure_count: 2
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert new_state.sensor_failure_count == 0
      assert new_state.mode == :pid
    end
  end

  describe "brew timer" do
    test "brew switch ON records brew_start_ms" do
      state = %Controller.State{
        mode: :pid,
        brew_switch_state: :off,
        brew_setpoint: 93.5,
        setpoint: 93.5,
        kp: 16.0, brew_kp: 16.0, brew_ki: 2.5, brew_kd: 16.0,
        ki: 2.5, kd: 16.0,
        error_sum: 0.0, last_error: 0,
        brew_cooling_compensation_c: 2.7, brew_kp_multiplier: 1.2,
        brew_start_ms: nil
      }

      {:noreply, new_state} = Controller.handle_info({:circuits_gpio, 27, 0, 0}, state)
      assert not is_nil(new_state.brew_start_ms)
    end

    test "brew switch OFF clears brew_start_ms" do
      state = %Controller.State{
        mode: :pid,
        brew_switch_state: :on,
        brew_setpoint: 93.5, setpoint: 96.2,
        kp: 16.0, brew_kp: 16.0, brew_ki: 2.5, brew_kd: 16.0,
        ki: 2.5, kd: 16.0,
        error_sum: 0.0, last_error: 0,
        brew_start_ms: System.monotonic_time(:millisecond) - 5000
      }

      {:noreply, new_state} = Controller.handle_info({:circuits_gpio, 27, 0, 1}, state)
      assert is_nil(new_state.brew_start_ms)
    end

    test "brew timeout disables heater after max brew time" do
      expired_start = System.monotonic_time(:millisecond) - 61_000

      state = %Controller.State{
        mode: :pid,
        initialized: true,
        brew_switch_state: :on,
        brew_start_ms: expired_start,
        setpoint: 96.2, reading: 96.0,
        kp: 1.0, ki: 0.01, kd: 0.0,
        error_sum: 0.0, last_error: 0,
        cycle_ms: 1000, max_integral: 20.0, min_output: 0, max_output: 100,
        sensor_failure_count: 0
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert new_state.mode == :disabled
      assert is_nil(new_state.brew_start_ms)
      assert_receive {:set_output, 0, 100}
    end
  end

  describe "auto-calibration on boot" do
    defmodule ColdHeater do
      def set_output(output, max_output), do: send(ExpressoFirmware.ControllerTest, {:set_output, output, max_output})
      def get_reading(), do: 20.0
    end

    test "init auto-starts calibration when uncalibrated and cold" do
      Application.put_env(:expresso_firmware, :heater_module, ColdHeater)
      {:ok, state} = Controller.init(calibrated: false)
      assert state.mode == :calibrating
      assert state.cal_start_temp == 20.0
      assert_receive {:set_output, 50, 100}
    end

    test "init skips calibration when already calibrated" do
      Application.put_env(:expresso_firmware, :heater_module, ColdHeater)
      {:ok, state} = Controller.init(calibrated: true)
      assert state.mode == :disabled
    end

    test "init skips calibration when warm and sets calibration_needed reason" do
      {:ok, state} = Controller.init(calibrated: false)
      # TestHeater returns 95°C > 40°C threshold
      assert state.mode == :disabled
      assert state.disable_reason == :calibration_needed
    end

    test "calibration completion sets calibrated: true and applies computed gains" do
      tmp = Path.join(System.tmp_dir!(), "cal_test_#{System.unique_integer()}.json")
      Application.put_env(:expresso_firmware, :config_path, tmp)
      on_exit(fn -> File.rm(tmp); Application.delete_env(:expresso_firmware, :config_path) end)

      tau_s = 60.0
      delta_ss = 50.0
      t_start = 20.0

      samples = for t_s <- 0..300//5 do
        {t_s * 1000, t_start + delta_ss * (1 - :math.exp(-t_s / tau_s))}
      end

      state = %Controller.State{
        mode: :calibrating,
        reading: t_start + delta_ss * (1 - :math.exp(-300.0 / tau_s)),
        cal_start_temp: t_start,
        cal_start_ms: System.monotonic_time(:millisecond) - 300_001,
        cal_samples: samples,
        cycle_ms: 1000,
        max_output: 100
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert new_state.calibrated == true
      assert new_state.brew_kp > 0
      assert new_state.kp == new_state.brew_kp
      assert_receive {:set_output, 0, 100}
    end
  end

  describe "step-response calibration" do
    test "start_calibration rejected when temperature is too high" do
      state = %Controller.State{mode: :disabled, reading: 50.0, max_output: 100}
      assert {:reply, {:error, :temperature_too_high}, ^state} =
               Controller.handle_call(:start_calibration, nil, state)
    end

    test "start_calibration rejected when already calibrating" do
      state = %Controller.State{mode: :calibrating, reading: 20.0, max_output: 100}
      assert {:reply, {:error, :already_calibrating}, ^state} =
               Controller.handle_call(:start_calibration, nil, state)
    end

    test "start_calibration transitions to :calibrating mode when cold" do
      state = %Controller.State{mode: :disabled, reading: 20.0, max_output: 100, cycle_ms: 1000}
      {:reply, :ok, new_state, _} = Controller.handle_call(:start_calibration, nil, state)
      assert new_state.mode == :calibrating
      assert new_state.cal_start_temp == 20.0
      assert not is_nil(new_state.cal_start_ms)
    end

    test "calibrating control loop records samples and applies step output" do
      t0 = System.monotonic_time(:millisecond)
      state = %Controller.State{
        mode: :calibrating,
        reading: 20.0,
        cal_start_temp: 20.0,
        cal_start_ms: t0,
        cal_samples: [{0, 20.0}],
        cycle_ms: 1000,
        max_output: 100
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert length(new_state.cal_samples) == 2
      assert_receive {:set_output, 50, 100}
    end

    test "calibration fit failure sets calibration_needed reason" do
      state = %Controller.State{
        mode: :calibrating,
        reading: 21.0,
        cal_start_temp: 20.0,
        cal_start_ms: System.monotonic_time(:millisecond) - 300_001,
        # Only one sample — temperature rise < 5°C → :insufficient_temperature_rise
        cal_samples: [{0, 20.0}, {300_000, 20.5}],
        cycle_ms: 1000,
        max_output: 100
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert new_state.mode == :disabled
      assert new_state.disable_reason == :calibration_needed
    end

    test "calibration completes and produces tau and process_gain" do
      # Simulate a first-order step response: T(t) = T_start + ΔT*(1 - e^(-t/tau))
      # With T_start=20, ΔT_ss=50 (at 50% output → pg=1.0), tau=60s
      tau_s = 60.0
      delta_ss = 50.0
      t_start = 20.0

      samples =
        for t_s <- 0..300//5 do
          temp = t_start + delta_ss * (1 - :math.exp(-t_s / tau_s))
          {t_s * 1000, temp}
        end

      t_end_ms = 300_000

      state = %Controller.State{
        mode: :calibrating,
        reading: t_start + delta_ss * (1 - :math.exp(-300.0 / tau_s)),
        cal_start_temp: t_start,
        cal_start_ms: System.monotonic_time(:millisecond) - t_end_ms - 1,
        cal_samples: samples,
        cycle_ms: 1000,
        max_output: 100
      }

      {:noreply, new_state, _} = Controller.handle_info(:control_loop, state)
      assert new_state.mode == :disabled
      # Tau should be in the right ballpark (within 20s of 60s)
      assert_in_delta new_state.tau_seconds, tau_s, 20.0
      # Process gain: delta_ss / step_output ≈ 50/50 = 1.0
      assert_in_delta new_state.process_gain, 1.0, 0.3
    end
  end
end
