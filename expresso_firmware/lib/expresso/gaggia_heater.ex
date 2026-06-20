defmodule ExpressoFirmware.GaggiaHeater do
  use GenServer

  @moduledoc """
    A stub heater to allow for the testing of a simple PID.
  """

  require Logger

  defmodule HeaterState do
    defstruct reading: 00.0,
              heater: :off,
              reading_loop_ms: 100,
              pwm_frequency_hz: 1,
              output: 0,
              # PWM module outputs 0-100, range for duty cycle is 0 - 1_000_000
              output_multiplier: 10000,
              pin: 12,
              max_reading: 165.0,
              override: false,
              sensor_module: Max31865,
              pwm_module: Pigpiox.Pwm,
              gpio_module: Pigpiox.GPIO
  end

  # --- Public Functions ---

  def start_link(config \\ []) do
    case Keyword.get(config, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, config)
      name -> GenServer.start_link(__MODULE__, config, name: name)
    end
  end

  @doc """
    Gets the current temperature of the heater
  """
  def get_reading(server \\ __MODULE__), do: GenServer.call(server, :get_reading)

  def set_output(output, max_output),
    do: set_output(__MODULE__, output, max_output)

  def set_output(server, output, max_output),
    do: GenServer.cast(server, {:set_output, output, max_output})

  # --- Callbacks ---

  @impl true
  def init(config) do
    state = struct(%HeaterState{}, config)
    disable_pwm(state)
    Process.send_after(self(), :reading_loop, state.reading_loop_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:set_output, output, max_output}, state) do
    output = apply_output(state, output, max_output)
    {:noreply, struct(state, %{output: output})}
  end

  @impl true
  def handle_call(:get_reading, _from, %HeaterState{reading: reading} = state) do
    {:reply, reading, state}
  end

  @impl true
  def handle_info(:reading_loop, state) do
    try do
      reading = state.sensor_module.get_temp()

      override =
        case reading >= state.max_reading do
          true ->
            Logger.error("Max temp of #{state.max_reading}c exceeded!  Overriding heater.")
            disable_pwm(state)
            true

          false ->
            false
        end

      Process.send_after(self(), :reading_loop, state.reading_loop_ms)

      {:noreply, struct(state, %{reading: reading, override: override})}
    rescue
      error ->
        disable_pwm(state)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        disable_pwm(state)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.error("GaggiaHeater terminating; forcing heater off. Reason: #{inspect(reason)}")
    disable_pwm(state)
    :ok
  end

  defp apply_output(%HeaterState{override: true} = state, output, _max_output) do
    Logger.info("Heater disabled, but received request for output of #{output}.")
    disable_pwm(state)
    0
  end

  defp apply_output(%HeaterState{override: false} = state, output, max_output) do
    output = floor(output * (1_000_000 / max_output))

    case state.pwm_module.hardware_pwm(state.pin, state.pwm_frequency_hz, output) do
      :ok ->
        output

      {:ok, _} ->
        output

      error ->
        Logger.error("Setting heater PWM failed; forcing heater off. Reason: #{inspect(error)}")
        disable_pwm(state)
        0
    end
  rescue
    error ->
      Logger.error("Setting heater PWM raised; forcing heater off. Reason: #{inspect(error)}")
      disable_pwm(state)
      0
  end

  defp disable_pwm(state) do
    [
      {:hardware_pwm,
       fn -> state.pwm_module.hardware_pwm(state.pin, state.pwm_frequency_hz, 0) end},
      {:gpio_pwm, fn -> state.pwm_module.gpio_pwm(state.pin, 0) end},
      {:gpio_output, fn -> state.gpio_module.set_mode(state.pin, :output) end},
      {:gpio_low, fn -> state.gpio_module.write(state.pin, 0) end}
    ]
    |> Enum.each(fn {operation, fun} -> safe_shutdown_call(operation, fun) end)
  end

  defp safe_shutdown_call(operation, fun) do
    case fun.() do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      error ->
        Logger.error("Heater shutdown operation #{operation} failed: #{inspect(error)}")
        :error
    end
  rescue
    error ->
      Logger.error("Heater shutdown operation #{operation} raised: #{inspect(error)}")
      :error
  end
end
