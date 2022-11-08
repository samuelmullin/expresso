defmodule ExpressoFirmware.GaggiaHeater do
  use GenServer

  @moduledoc """
    A stub heater to allow for the testing of a simple PID.
  """

  require Logger
  alias Pigpiox.Pwm

  defmodule HeaterState do
    defstruct reading: 00.0,
              heater: :off,
              reading_loop_ms: 100,
              pwm_frequency_hz: 1,
              output: 0,
              output_multiplier: 10000, # PWM module outputs 0-100, range for duty cycle is 0 - 1_000_000
              pin: 12,
              max_reading: 160.0,
              override: false
  end

  # --- Public Functions ---

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
    Gets the current temperature of the heater
  """
  def get_reading(), do: GenServer.call(__MODULE__, :get_reading)

  def set_output(output, max_output),
    do: GenServer.cast(__MODULE__, {:set_output, output, max_output})

  # --- Callbacks ---

  @impl true
  def init(_) do
    state = %HeaterState{}
    Process.send_after(self(), :reading_loop, state.reading_loop_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:set_output, output, max_output}, state) do
    output = set_output(state, output, max_output)
    {:noreply, struct(state, %{output: output})}
  end

  @impl true
  def handle_call(:get_reading, _from, %HeaterState{reading: reading} = state) do
    {:reply, reading, state}
  end

  @impl true
  def handle_info(:reading_loop, state) do
    reading = Max31865.get_temp()

    override = case reading >= state.max_reading do
      true ->
        Logger.error("Max temp of #{state.max_reading}c exceeded!  Overriding heater.")
        Pwm.hardware_pwm(state.pin, state.pwm_frequency_hz, 0)
        true
      false ->
        false
    end
    Process.send_after(self(), :reading_loop, state.reading_loop_ms)

    {:noreply, struct(state, %{reading: reading, override: override})}
  end

  defp set_output(%HeaterState{override: true} = state, _output, _max_output) do
    Pwm.hardware_pwm(state.pin, state.pwm_frequency_hz, 0)
    0
  end

  defp set_output(%HeaterState{override: false} = state, output, max_output) do
    output = floor(output * (1_000_000 / max_output))
    Pwm.hardware_pwm(state.pin, state.pwm_frequency_hz, output)
    output
  end

end
