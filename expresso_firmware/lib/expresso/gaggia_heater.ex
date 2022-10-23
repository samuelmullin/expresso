defmodule ExpressoFirmware.GaggiaHeater do
  use GenServer

  @moduledoc """
    A stub heater to allow for the testing of a simple PID.
  """

  require Logger

  defmodule HeaterState do
    defstruct temp: 00.0,
              heater: :off,
              heater_cycle_ms: 100,
              output: 0,
              pin: 6,
              output_ref: nil,
              max_temp: 160.0,
              override: false
  end

  # --- Public Functions ---

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
    Gets the current temperature of the heater
  """
  def get_temp(), do: GenServer.call(__MODULE__, :get_temp)

  def set_heater_output(output, max_output), do: GenServer.cast(__MODULE__, {:set_output, output, max_output})

  # --- Callbacks ---

  @impl true
  def init(_) do
    state = %HeaterState{}
    {:ok, output_ref} = Circuits.GPIO.open(state.pin, :output, initial_value: 0)
    state = struct(state, output_ref: output_ref)

    Process.send_after(self(), :heater_loop, 100)

    {:ok, state}
  end

  @impl true
  def handle_cast({:set_output, output}, state) do
    {:noreply, struct(state, %{output: output})}
  end

  @impl true
  def handle_call(:get_temp, _from, %HeaterState{temp: temp} = state) do
    {:reply, temp, state}
  end

  @impl true
  def handle_info(:reading_loop, state) do
    temp = Max31865.get_temp()

    override = case temp >= state.max_temp do
      true ->
        Logger.error("Max temp of #{state.max_temp}c exceeded!  Overriding heater.")
        set_heater_off(state.output_ref)
        true
      false ->
        false
    end
    Process.send_after(self(), :heater_loop, state.heater_cycle_ms)

    {:noreply, struct(state, %{temp: temp, override: override})}
  end

  defp set_heater_on(output_ref, false) do
    Circuits.GPIO.write(output_ref, 1)
  end

  defp set_heater_on(output_ref, true) do
    Circuits.GPIO.write(output_ref, 0)
  end

  defp set_heater_off(output_ref) do
    Circuits.GPIO.write(output_ref, 0)
  end


end
