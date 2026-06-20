defmodule ExpressoFirmware.Controller do
  use GenServer

  require Logger
  alias Circuits.GPIO

  @moduledoc """
  PID goes brrr
  """

  @brew_switch_pin Application.compile_env!(:expresso_firmware, :brew_switch_pin)
  @steam_switch_pin Application.compile_env!(:expresso_firmware, :steam_switch_pin)

  @brew_cooling_rate_c_per_sec 0.1
  @typical_brew_duration_sec 27
  @brew_cooling_compensation_c @brew_cooling_rate_c_per_sec * @typical_brew_duration_sec  # ~2.7°C
  @brew_kp_multiplier 1.2

  # Lambda Tuning parameters
  @default_tau_seconds 45.0
  @default_lambda_seconds 10.0
  @default_process_gain 1.0

  defmodule State do
    defstruct kp: 16.0,
              base_kp: 16.0,
              ki: 2.5,
              kd: 16.0,
              tau_seconds: 45.0,
              process_gain: 1.0,
              cycle_ms: 1000,
              reporting_interval_ms: 100,
              setpoint: 101.0,
              brew_setpoint: 101.0,
              steam_setpoint: 155.0,
              max_integral: 20.0,
              min_output: 0,
              max_output: 100,
              brew_pwm_output: 30.0,
              brew_switch_ref: nil,
              steam_switch_ref: nil,
              brew_switch_state: :off,
              steam_switch_state: :off,
              mode: :disabled,
              reading: 20.0,
              last_error: 0,
              last_output: 0,
              error_sum: 0.0,
              initialized: false
  end

  # --- Public API ---

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(config \\ []) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def set_config(new_config), do: GenServer.call(__MODULE__, {:set_config, new_config})
  def set_config(key, value), do: GenServer.call(__MODULE__, {:set_config, key, value})
  def get_state(), do: GenServer.call(__MODULE__, :get_state)

  @doc """
  Calculate PID gains using Lambda Tuning method.
  """
  def calculate_lambda_gains(tau_seconds \\ @default_tau_seconds, lambda_seconds \\ @default_lambda_seconds, process_gain \\ @default_process_gain) do
    kp = (1 / process_gain) * (tau_seconds / (lambda_seconds + tau_seconds))
    ki = kp / (tau_seconds + lambda_seconds)
    kd = 0

    {kp, ki, kd}
  end

  def autotune_lambda(lambda_seconds) do
    GenServer.call(__MODULE__, {:autotune_lambda, lambda_seconds})
  end

  @impl true
  def init(config) do
    # Open our brew and steam switches and set interrupts for the GPIO.  This will
    # send an initial message so we can properly set the initial state.
    {:ok, brew_switch_ref} = GPIO.open(@brew_switch_pin, :input, pull_mode: :pullup)
    Circuits.GPIO.set_interrupts(brew_switch_ref, :both)
    {:ok, steam_switch_ref} = GPIO.open(@steam_switch_pin, :input, pull_mode: :pullup)
    Circuits.GPIO.set_interrupts(steam_switch_ref, :both)

    # Calculate PID gains using Lambda Tuning unless overridden in config
    tau = Keyword.get(config, :tau_seconds, @default_tau_seconds)
    lambda = Keyword.get(config, :lambda_seconds, @default_lambda_seconds)
    process_gain = Keyword.get(config, :process_gain, @default_process_gain)

    {kp, ki, kd} = calculate_lambda_gains(tau, lambda, process_gain)

    Logger.info(
      "Controller initialized with Lambda Tuning gains: " <>
      "kp=#{Float.round(kp, 2)}, ki=#{Float.round(ki, 2)}, kd=#{kd} " <>
      "(tau=#{tau}s, lambda=#{lambda}s)"
    )

    config_with_gains =
      config
      |> Keyword.put(:kp, kp)
      |> Keyword.put(:ki, ki)
      |> Keyword.put(:kd, kd)
      |> Keyword.put(:base_kp, kp)  # anchor for brew boost/restore
      |> Keyword.put(:tau_seconds, tau)
      |> Keyword.put(:process_gain, process_gain)

    # Start control loop
    Process.send_after(self(), :control_loop, 1000)

    {:ok,
     struct(
       State,
       config_with_gains ++ [brew_switch_ref: brew_switch_ref, steam_switch_ref: steam_switch_ref]
     )}
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
  def handle_call({:autotune_lambda, lambda_seconds}, _from, state) do
    {new_kp, new_ki, new_kd} = calculate_lambda_gains(state.tau_seconds, lambda_seconds, state.process_gain)

    Logger.info(
      "Re-tuning with lambda=#{lambda_seconds}s: " <>
      "new gains: kp=#{Float.round(new_kp, 2)}, ki=#{Float.round(new_ki, 2)}, kd=#{new_kd}"
    )

    new_state = struct(state, kp: new_kp, ki: new_ki, kd: new_kd, base_kp: new_kp)
    {:reply, {new_kp, new_ki, new_kd}, new_state}
  end

  @impl true
  def handle_cast(:enable_pid, %State{} = state) do
    Logger.info("Enabling PID")

    mode =
      case state.brew_switch_state do
        :on -> :pwm
        :off -> :pid
      end

    {:noreply, struct(state, mode: mode, initialized: false)}
  end

  @impl true
  def handle_cast(:disable_pid, %State{} = state) do
    Logger.info("Disabling PID")
    heater().set_output(0, state.max_output)

    {:noreply, struct(state, mode: :disabled)}
  end

  @impl true
  def handle_info({:circuits_gpio, @brew_switch_pin, _timestamp, 1}, state) do
    Logger.info(
      "Brew switch OFF - returning to normal PID. " <>
      "Restore setpoint to #{state.brew_setpoint}°C and Kp to normal"
    )

    normal_state = struct(state,
      brew_switch_state: :off,
      mode: :pid,
      initialized: false,  # Re-initialize PID for new setpoint
      setpoint: state.brew_setpoint,
      kp: state.base_kp,  # Restore original Kp
      error_sum: 0.0,
      last_error: 0
    )

    {:noreply, normal_state}
  end

  @impl true
  def handle_info({:circuits_gpio, @brew_switch_pin, _timestamp, 0}, state) do
    Logger.info(
      "Brew switch ON - activating PID with feedforward compensation. " <>
      "Boost setpoint by #{@brew_cooling_compensation_c}°C and Kp by #{@brew_kp_multiplier}×"
    )

    # Enter PID mode (not PWM) with boosted setpoint and Kp to compensate for measured cooling
    boosted_state = struct(state,
      brew_switch_state: :on,
      mode: :pid,
      initialized: false,  # Re-initialize PID for new setpoint
      setpoint: state.brew_setpoint + @brew_cooling_compensation_c,
      kp: state.base_kp * @brew_kp_multiplier,
      error_sum: 0.0,
      last_error: 0
    )

    {:noreply, boosted_state}
  end

  @impl true
  def handle_info({:circuits_gpio, @steam_switch_pin, _timestamp, 1}, state) do
    Logger.info("Steam switch set to :off, changing setpoint to brew temp")
    {:noreply, struct(state, steam_switch_state: :off, setpoint: state.brew_setpoint, initialized: false)}
  end

  @impl true
  def handle_info({:circuits_gpio, @steam_switch_pin, _timestamp, 0}, state) do
    Logger.info("Steam switch set to :on, changing setpoint to steam temp")
    {:noreply, struct(state, steam_switch_state: :on, setpoint: state.steam_setpoint, initialized: false)}
  end

  @impl true
  def handle_info({:circuits_gpio, pin, _timestamp, value}, state) do
    Logger.info("That pin was unexpected!  Pin: #{pin} value: #{value}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:control_loop, %State{mode: :pid, initialized: false} = state) do
    # First control cycle: read sensor and initialize last_error without calculating PID
    reading = get_reading()

    Logger.debug("PID controller initializing: setpoint=#{state.setpoint}, reading=#{reading}")

    state =
      struct(state,
        reading: reading,
        last_error: state.setpoint - reading,
        initialized: true
      )

    Process.send_after(self(), :control_loop, state.cycle_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:control_loop, %State{mode: :pid, initialized: true} = state) do
    # Compute PID Vars
    reading = get_reading()
    error = state.setpoint - reading
    error_change = error - state.last_error

    # Calculate output first (before clamping) to detect saturation
    unclamped_output = state.kp * error + state.ki * state.error_sum + state.kd * error_change

    # Anti-windup: only accumulate integral if output is NOT saturated
    error_sum =
      if unclamped_output >= state.max_output or unclamped_output <= state.min_output do
        state.error_sum  # Hold integral constant when saturated
      else
        clamp_integral(state.error_sum + error, state.max_integral)
      end

    # Now clamp the output
    output =
      unclamped_output
      |> floor()
      |> clamp_output(state.min_output, state.max_output)

    # Update the state with the new calculated variables and enable the heater if necessary
    state =
      struct(state,
        error_sum: error_sum,
        last_output: output,
        last_error: error,
        reading: reading
      )

    heater().set_output(output, state.max_output)

    Process.send_after(self(), :control_loop, state.cycle_ms)

    {:noreply, state}
  end

  @impl true
  def handle_info(:control_loop, %State{mode: :pwm} = state) do
    Logger.warning(
      "PWM mode is deprecated. Brew phase now uses intelligent PID with feedforward. " <>
      "Treating as :pid mode."
    )

    # Delegate to PID mode handler (will handle the next control loop)
    handle_info(:control_loop, struct(state, mode: :pid, initialized: false))
  end

  @impl true
  def handle_info(:control_loop, %State{mode: :disabled} = state) do
    Logger.debug("Heater control is disabled")
    Process.send_after(self(), :control_loop, state.cycle_ms)
    {:noreply, struct(state, last_output: 0, last_error: 0, error_sum: 0)}
  end

  @impl true
  def handle_info(message, state) do
    Logger.info(
      "Unxpected info message received!  Killing PID output.  Message: #{inspect(message)} State: #{inspect(state)}"
    )

    heater().set_output(0, state.max_output)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %State{} = state) do
    Logger.error("Controller terminating; forcing heater off. Reason: #{inspect(reason)}")
    shutdown_heater(state)
    :ok
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

  defp shutdown_heater(state) do
    heater().set_output(0, state.max_output)
    :ok
  rescue
    error ->
      Logger.error("Controller heater shutdown raised: #{inspect(error)}")
      :error
  catch
    kind, reason ->
      Logger.error("Controller heater shutdown failed: #{inspect({kind, reason})}")
      :error
  end

  defp heater(),
    do: Application.get_env(:expresso_firmware, :heater_module, ExpressoFirmware.StubHeater)
end
