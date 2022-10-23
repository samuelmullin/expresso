defmodule ExpressoFirmware.PID do
  use GenServer

  require Logger

  @moduledoc """


  """

  defmodule PIDState do
    defstruct kp: 24.0,
              ki: 4.0,
              kd: 0.0,
              cycle_ms: 2000,
              reporting_interval_ms: 100,
              setpoint: 101.0,
              brew_setpoint: 101.0,
              steam_setpoint: 157.0,
              max_integral: 20.0,
              min_output: 15,
              max_output: 255,
              mode: :brew,
              reading: 20.0,
              last_value: 0,
              last_error: 0,
              last_output: 0,
              error_sum: 0.0,
              status: :disabled

  end

  # --- Public API ---

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def set_config(new_config), do: GenServer.call(__MODULE__, {:set_config, new_config})
  def set_config(key, value), do: GenServer.call(__MODULE__, {:set_config, key, value})
  def get_state(), do: GenServer.call(__MODULE__, :get_state)

  @impl true
  def init(config) do
    state = %PIDState{}

    Process.send_after(self(), :enable_pid, 1000)

    {:ok, state}
  end

  # --- Callbacks ---

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:set_config, :mode, :steam}, _, %PIDState{} = state) do
    state = struct(state, %{mode: :steam, setpoint: state.steam_setpoint})
    {:reply, :steam, state}
  end
  def handle_call({:set_config, :mode, :brew}, _, %PIDState{} = state) do
    state = struct(state, %{mode: :brew, setpoint: state.brew_setpoint})
    {:reply, :brew, state}
  end
  def handle_call({:set_config, new_config}, _, %PIDState{} = state) do
    state = struct(state, new_config)
    {:reply, state, state}
  end

  @impl true
  def handle_info(:pid_loop, %PIDState{status: :disabled} = state) do
    heater().set_output(0, state.max_output)
    Process.send_after(self(), :pid_loop, state.cycle_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:pid_loop, %PIDState{status: :enabled} = state) do
    # Compute PID Vars
    reading = get_reading()
    error = state.setpoint - reading
    error_change = error - state.last_error
    error_sum = clamp_integral(state.error_sum + error, state.max_integral)

    # Calculate output
    output = ((state.kp * error) + (state.ki * error_sum) + (state.kd * error_change))
    |> floor()
    |> clamp_output(state.min_output, state.max_output)

    # Update the state with the new calculated variables and enable the heater if necessary
    state = struct(state, %{
      error_sum: error_sum,
      last_output: output,
      last_error: error,
      reading: reading
    })

    heater().set_output(output, state.max_output)

    Process.send_after(self(), :pid_loop, state.cycle_ms)

    {:noreply, state}
  end

  @impl true
  def handle_info(:enable_pid, %PIDState{} = state) do
    Process.send_after(self(), :pid_loop, 100)
    {:noreply, state |> Map.put(:status, :enabled)}
  end

  @impl true
  def handle_info(:disable_pid, %PIDState{} = state) do
    heater().set_output(0, state.max_output)
    Process.send_after(self(), :pid_loop, 100)
    {:noreply, state |> Map.put(:status, :disabled)}
  end

  @impl true
  def handle_info(_, state) do
    Logger.info("#{inspect(state)}")
    {:noreply, state}
  end

  # --- Private API ---

  # Our output is the % of the Duty Cycle that the Heater should run.  A value of 25.0 will run
  # the heater for 25% of the configured duty cycle.  The max and min output values are configurable.
  defp clamp_output(output, min_output, _max_output) when output < min_output, do: 0
  defp clamp_output(output, _min_output, max_output) when output > max_output, do: max_output
  defp clamp_output(output, _, _), do: output

  # Clamp the integral to prevent integral windup
  defp clamp_integral(integral, max_integral) when integral > max_integral, do: max_integral
  defp clamp_integral(integral, max_integral) when integral < -max_integral, do: -max_integral
  defp clamp_integral(integral, _), do: integral

  defp get_reading(), do: heater().get_reading()

  defp heater(), do: Application.get_env(:expresso_firmware, :heater_module, ExpressoFirmware.StubHeater)

end
