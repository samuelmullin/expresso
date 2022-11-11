defmodule ExpressoFirmware.Controller do
  use GenServer

  require Logger
  alias Circuits.GPIO

  @moduledoc """
  PID goes brrr
  """

  @brew_switch_pin 27

  defmodule State do
    defstruct kp: 16.0,
              ki: 2.5,
              kd: 16.0,
              cycle_ms: 1000,
              reporting_interval_ms: 100,
              setpoint: 101.0,
              brew_setpoint: 101.0,
              steam_setpoint: 155.0,
              max_integral: 20.0,
              min_output: 0,
              max_output: 100,
              brew_pwm_output: 50.0,
              brew_switch_ref: nil,
              steam_switch_ref: nil,
              brew_switch_state: :off,
              steam_switch_state: :off,
              mode: :disabled,
              reading: 20.0,
              last_error: 0,
              last_output: 0,
              error_sum: 0.0
  end

  # --- Public API ---

  def start_link(config \\ []) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def set_config(new_config), do: GenServer.call(__MODULE__, {:set_config, new_config})
  def set_config(key, value), do: GenServer.call(__MODULE__, {:set_config, key, value})
  def get_state(), do: GenServer.call(__MODULE__, :get_state)

  @impl true
  def init(config) do
    # Open our brew switch and set interrupts for the GPIO.  This will send an initial
    # message so we can properly set the initial brew switch state.
    {:ok, brew_switch_ref} = GPIO.open(@brew_switch_pin, :input, pull_mode: :pullup)
    Circuits.GPIO.set_interrupts(brew_switch_ref, :both)

    # Start control loop
    Process.send_after(self(), :control_loop, 1000)

    {:ok, struct(%State{}, config ++ [brew_switch_ref: brew_switch_ref])}
  end

  # --- Callbacks ---
  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:set_config, new_config}, _, %State{} = state) do
    state = struct(state, new_config)
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:enable_pid, %State{} = state) do
    Logger.info("Enabling PID")
    mode = case state.brew_switch_state do
      :on -> :pwm
      :off -> :pid
    end

    {:noreply, struct(state, [mode: mode])}
  end

  @impl true
  def handle_cast(:disable_pid, %State{} = state) do
    Logger.info("Disabling PID")
    heater().set_output(0, state.max_output)

    {:noreply, struct(state, [mode: :disabled])}
  end

  @impl true
  def handle_info({:circuits_gpio, @brew_switch_pin, _timestamp, 1}, state) do
    Logger.info("Brew switch set to :off, enabling :pid mode")
    {:noreply, struct(state, [brew_switch_state: :off, mode: :pid])}
  end

  @impl true
  def handle_info({:circuits_gpio, @brew_switch_pin, _timestamp, 0}, state) do
    Logger.info("Brew switch set to :on, enabling :pwm mode")
    {:noreply, struct(state, [brew_switch_state: :on, mode: :pwm])}
  end

  @impl true
  def handle_info({:circuits_gpio, pin, _timestamp, value}, state) do
    Logger.info("That pin was unexpected!  Pin: #{pin} value: #{value}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:control_loop, %State{mode: :pid} = state) do
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
    state = struct(state, [
      error_sum: error_sum,
      last_output: output,
      last_error: error,
      reading: reading
    ])

    heater().set_output(output, state.max_output)

    Process.send_after(self(), :control_loop, state.cycle_ms)

    {:noreply, state}
  end

  @impl true
  def handle_info(:control_loop, %State{mode: :pwm} = state) do
    Logger.info("Heater control is in :pwm mode with setpoint: #{state.setpoint}")
    heater().set_output(state.brew_pwm_output, state.max_output)
    Process.send_after(self(), :control_loop, state.cycle_ms)
    {:noreply, struct(state, [last_output: 0, last_error: 0, error_sum: 0])}
  end

  @impl true
  def handle_info(:control_loop, %State{mode: :disabled} = state) do
    Logger.debug("Heater control is disabled")
    Process.send_after(self(), :control_loop, state.cycle_ms)
    {:noreply, struct(state, [last_output: 0, last_error: 0, error_sum: 0])}
  end

  @impl true
  def handle_info(message, state) do
    Logger.info("Unxpected info message received!  Killing PID output.  Message: #{inspect(message)} State: #{inspect(state)}")
    heater().set_output(0, state.max_output)
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
