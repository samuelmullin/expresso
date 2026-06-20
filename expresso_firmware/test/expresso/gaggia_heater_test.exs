defmodule ExpressoFirmware.GaggiaHeaterTest do
  use ExUnit.Case

  alias ExpressoFirmware.GaggiaHeater

  defmodule RaisingSensor do
    def get_temp(), do: raise("sensor offline")
  end

  defmodule TestPwm do
    def hardware_pwm(pin, frequency, duty_cycle) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:hardware_pwm, pin, frequency, duty_cycle})
      :ok
    end

    def gpio_pwm(pin, duty_cycle) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:gpio_pwm, pin, duty_cycle})
      :ok
    end
  end

  defmodule FailingOffPwm do
    def hardware_pwm(pin, frequency, 0) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:hardware_pwm, pin, frequency, 0})
      {:error, :offline}
    end

    def hardware_pwm(pin, frequency, duty_cycle) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:hardware_pwm, pin, frequency, duty_cycle})
      :ok
    end

    def gpio_pwm(pin, duty_cycle) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:gpio_pwm, pin, duty_cycle})
      :ok
    end
  end

  defmodule FailingSetPwm do
    def hardware_pwm(pin, frequency, 0) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:hardware_pwm, pin, frequency, 0})
      :ok
    end

    def hardware_pwm(pin, frequency, duty_cycle) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:hardware_pwm, pin, frequency, duty_cycle})
      {:error, :offline}
    end

    def gpio_pwm(pin, duty_cycle) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:gpio_pwm, pin, duty_cycle})
      :ok
    end
  end

  defmodule TestGpio do
    def set_mode(pin, mode) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:gpio_set_mode, pin, mode})
      :ok
    end

    def write(pin, level) do
      send(ExpressoFirmware.GaggiaHeaterTest, {:gpio_write, pin, level})
      :ok
    end
  end

  setup do
    Process.register(self(), __MODULE__)

    on_exit(fn ->
      if Process.whereis(__MODULE__) == self() do
        Process.unregister(__MODULE__)
      end
    end)
  end

  test "turns pwm off before exiting when the temperature sensor raises" do
    Process.flag(:trap_exit, true)

    {:ok, heater} =
      GaggiaHeater.start_link(
        name: nil,
        sensor_module: RaisingSensor,
        pwm_module: TestPwm,
        gpio_module: TestGpio,
        reading_loop_ms: :timer.hours(1)
      )

    assert_receive {:hardware_pwm, 12, 1, 0}
    assert_receive {:gpio_pwm, 12, 0}
    assert_receive {:gpio_set_mode, 12, :output}
    assert_receive {:gpio_write, 12, 0}

    GaggiaHeater.set_output(heater, 50, 100)
    assert_receive {:hardware_pwm, 12, 1, 500_000}

    send(heater, :reading_loop)

    assert_receive {:hardware_pwm, 12, 1, 0}
    assert_receive {:EXIT, ^heater, {%RuntimeError{message: "sensor offline"}, _stack}}
  end

  test "turns pwm off when the heater starts" do
    {:ok, _heater} =
      GaggiaHeater.start_link(
        name: nil,
        pwm_module: TestPwm,
        gpio_module: TestGpio,
        reading_loop_ms: :timer.hours(1)
      )

    assert_receive {:hardware_pwm, 12, 1, 0}
    assert_receive {:gpio_pwm, 12, 0}
    assert_receive {:gpio_set_mode, 12, :output}
    assert_receive {:gpio_write, 12, 0}
  end

  test "falls back to software pwm and gpio low when hardware pwm off fails" do
    Process.flag(:trap_exit, true)

    {:ok, heater} =
      GaggiaHeater.start_link(
        name: nil,
        sensor_module: RaisingSensor,
        pwm_module: FailingOffPwm,
        gpio_module: TestGpio,
        reading_loop_ms: :timer.hours(1)
      )

    assert_receive {:hardware_pwm, 12, 1, 0}
    assert_receive {:gpio_pwm, 12, 0}
    assert_receive {:gpio_set_mode, 12, :output}
    assert_receive {:gpio_write, 12, 0}

    send(heater, :reading_loop)

    assert_receive {:hardware_pwm, 12, 1, 0}
    assert_receive {:gpio_pwm, 12, 0}
    assert_receive {:gpio_set_mode, 12, :output}
    assert_receive {:gpio_write, 12, 0}
    assert_receive {:EXIT, ^heater, {%RuntimeError{message: "sensor offline"}, _stack}}
  end

  test "falls back to shutdown when setting nonzero hardware pwm fails" do
    {:ok, heater} =
      GaggiaHeater.start_link(
        name: nil,
        pwm_module: FailingSetPwm,
        gpio_module: TestGpio,
        reading_loop_ms: :timer.hours(1)
      )

    assert_receive {:hardware_pwm, 12, 1, 0}
    assert_receive {:gpio_pwm, 12, 0}
    assert_receive {:gpio_set_mode, 12, :output}
    assert_receive {:gpio_write, 12, 0}

    GaggiaHeater.set_output(heater, 50, 100)

    assert_receive {:hardware_pwm, 12, 1, 500_000}
    assert_receive {:hardware_pwm, 12, 1, 0}
    assert_receive {:gpio_pwm, 12, 0}
    assert_receive {:gpio_set_mode, 12, :output}
    assert_receive {:gpio_write, 12, 0}
  end
end
