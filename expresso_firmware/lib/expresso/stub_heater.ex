defmodule ExpressoFirmware.StubHeater do
  use GenServer

  @moduledoc """
    A stub heater to allow for the testing of a simple PID.
  """

  defmodule HeaterState do
    defstruct reading: 00.0,
              heater: :off,
              heater_cycle_ms: 10,
              pwm_cycle_ms: 1000,
              output: 0,
              override: false,
              heating_delta_per_second: 1.83,
              cooling_delta_per_second: 0.099,
              pin: 12,
              max_temp: 160.0,
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

  def set_output(output, max_output),
    do: GenServer.cast(__MODULE__, {:set_output, output, max_output})

  # --- Callbacks ---

  @impl true
  def init(_) do
    state = %HeaterState{}
    {:ok, output_ref} = Circuits.GPIO.open(state.pin, :output, initial_value: 0)
    state = struct(state, output_ref: output_ref)

    Process.send_after(self(), :heater_loop, 100)
    Process.send_after(self(), :pid_loop, 1000)

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
  def handle_info(:heater_loop, %HeaterState{} = state) do
    reading = case state.heater do
      :on ->
        state.reading + (state.heating_delta_per_second / 100)
      :off ->
        state.reading - (state.cooling_delta_per_second / 100)
    end
    override = reading > state.max_temp
    Process.send_after(self(), :heater_loop, state.heater_cycle_ms)
    {:noreply, struct(state, %{reading: reading, override: override})}
  end

  @impl true
  def handle_info(:pid_loop, %HeaterState{output: output} = state) do
    Pigpiox.GPIO.write(state.pin, 1)
    Process.send_after(self(), {:heater_off, output}, output)
    {:noreply, struct(state, %{heater: :on})}
  end

  @impl true
  def handle_info({:heater_off, output}, %HeaterState{} = state) do
    Pigpiox.GPIO.write(state.pin, 0)
    Process.send_after(self(), :pid_loop, state.pwm_cycle_ms - output)
    {:noreply, struct(state, %{heater: :off})}
  end

  def set_output(%HeaterState{override: true} = state, _output, _max_output) do
    Pigpiox.GPIO.write(state.pin, 0)
    0
  end

  def set_output(%HeaterState{} = state, output, max_output) do
    floor(output * state.pwm_cycle_ms / max_output)
  end



end
