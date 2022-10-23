defmodule ExpressoFirmware.StubHeater do
  use GenServer

  @moduledoc """
    A stub heater to allow for the testing of a simple PID.
  """

  defmodule HeaterState do
    defstruct reading: 00.0,
              heater: :off,
              heater_cycle_ms: 10,
              output: 0,
              max_output: 255,
              heating_delta_per_second: 1.83,
              cooling_delta_per_second: 0.099,
              pin: 6,
              output_ref: nil
  end

  # --- Public Functions ---

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
    Gets the current temperature of the heater
  """
  def get_reading(), do: GenServer.call(__MODULE__, :get_reading)

  def set_output(output, max_output), do: GenServer.cast(__MODULE__, {:set_output, output, max_output})

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
  def handle_cast({:set_output, output, max_output}, state) do
    {:noreply, struct(state, %{output: output, max_output: max_output})}
  end

  @impl true
  def handle_call(:get_reading, _from, %HeaterState{reading: reading} = state) do
    {:reply, reading, state}
  end

  @impl true
  def handle_info(:heater_loop, %HeaterState{output: 0} = state) do
    reading = state.reading - (state.cooling_delta_per_second / 1000 * state.heater_cycle_ms)
    Process.send_after(self(), :heater_loop, state.heater_cycle_ms)

    {:noreply, struct(state, %{reading: reading})}
  end

  @impl true
  def handle_info(:heater_loop, %HeaterState{output: output, max_output: max_output} = state) do
    output_pct = output / max_output
    temp_increase = state.heating_delta_per_second / 1000 * state.heater_cycle_ms * output_pct
    temp_decrease = state.cooling_delta_per_second / 1000 * state.heater_cycle_ms * (1 - output_pct)
    reading = state.reading + temp_increase - temp_decrease
    Process.send_after(self(), :heater_loop, state.heater_cycle_ms)
    {:noreply, state |> Map.put(:reading, reading)}
  end


end
