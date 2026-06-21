defmodule ExpressoFirmware.Controller do
  use GenServer

  require Logger
  alias Circuits.GPIO
  alias ExpressoFirmware.Config
  alias ExpressoFirmware.History

  @moduledoc """
  PID goes brrr
  """

  @brew_switch_pin Application.compile_env!(:expresso_firmware, :brew_switch_pin)
  @steam_switch_pin Application.compile_env!(:expresso_firmware, :steam_switch_pin)

  # Lambda Tuning parameters
  @default_tau_seconds 45.0
  @default_lambda_seconds 10.0
  @default_steam_lambda_seconds 15.0
  @default_process_gain 1.0
  @history_max 600
  @history_flush_every 30

  # Keys that are safe to persist to / load from the config file.
  # Runtime-only State fields (mode, initialized, brew_switch_state, error_sum, etc.) are excluded.
  @persisted_keys [
    :autotune_enabled, :brew_kp, :brew_ki, :brew_kd, :lambda_seconds,
    :tau_seconds, :process_gain, :brew_setpoint, :steam_setpoint,
    :brew_cooling_compensation_c, :brew_kp_multiplier,
    :steam_kp, :steam_ki, :steam_kd, :steam_lambda_seconds
  ]

  # Gain fields owned by the autotune system. When autotune is enabled, set_config
  # rejects changes to these — they are controlled exclusively by autotune_lambda.
  @autotune_managed_keys [:kp, :ki, :kd, :brew_kp, :brew_ki, :brew_kd, :steam_kp, :steam_ki, :steam_kd]

  defmodule State do
    defstruct kp: 16.0,
              ki: 2.5,
              kd: 16.0,
              # Brew-mode gain anchors (source of truth; active kp/ki/kd is set from these)
              brew_kp: 16.0,
              brew_ki: 2.5,
              brew_kd: 16.0,
              # Steam-mode gains
              steam_kp: 0.75,
              steam_ki: 0.0125,
              steam_kd: 0.0,
              steam_lambda_seconds: 15.0,
              # Lambda Tuning parameters
              tau_seconds: 45.0,
              process_gain: 1.0,
              lambda_seconds: 10.0,
              # Brew phase feedforward (moved from module attributes)
              brew_cooling_compensation_c: 2.7,
              brew_kp_multiplier: 1.2,
              # Autotune toggle
              autotune_enabled: true,
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
              initialized: false,
              history: :queue.new(),
              history_count: 0,
              history_flush_counter: 0
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
  def get_state(), do: GenServer.call(__MODULE__, :get_state)
  def get_history(), do: GenServer.call(__MODULE__, :get_history)

  @doc """
  Calculate PID gains using Lambda Tuning method.
  """
  def calculate_lambda_gains(
        tau_seconds \\ @default_tau_seconds,
        lambda_seconds \\ @default_lambda_seconds,
        process_gain \\ @default_process_gain
      ) do
    kp = 1 / process_gain * (tau_seconds / (lambda_seconds + tau_seconds))
    ki = kp / (tau_seconds + lambda_seconds)
    kd = 0

    {kp, ki, kd}
  end

  def autotune_lambda(lambda_seconds) do
    GenServer.call(__MODULE__, {:autotune_lambda, lambda_seconds})
  end

  @impl true
  def init(config) do
    {:ok, brew_switch_ref} = GPIO.open(@brew_switch_pin, :input, pull_mode: :pullup)
    Circuits.GPIO.set_interrupts(brew_switch_ref, :both)
    {:ok, steam_switch_ref} = GPIO.open(@steam_switch_pin, :input, pull_mode: :pullup)
    Circuits.GPIO.set_interrupts(steam_switch_ref, :both)

    # File config wins over passed-in config for user-facing settings.
    # Only allowed persisted keys are merged to prevent hand-edited runtime fields
    # (e.g. mode: :pid) from taking effect on boot.
    file_config =
      case Config.load() do
        {:ok, map} -> map |> Map.to_list() |> Keyword.new() |> Keyword.take(@persisted_keys)
        _ -> []
      end

    merged = Keyword.merge(config, file_config)

    autotune_enabled = Keyword.get(merged, :autotune_enabled, true)
    tau = Keyword.get(merged, :tau_seconds, @default_tau_seconds)
    lambda = Keyword.get(merged, :lambda_seconds, @default_lambda_seconds)
    steam_lambda = Keyword.get(merged, :steam_lambda_seconds, @default_steam_lambda_seconds)
    process_gain = Keyword.get(merged, :process_gain, @default_process_gain)

    merged =
      if autotune_enabled do
        {brew_kp, brew_ki, brew_kd} = calculate_lambda_gains(tau, lambda, process_gain)
        {steam_kp, steam_ki, steam_kd} = calculate_lambda_gains(tau, steam_lambda, process_gain)

        Logger.info(
          "Controller init: autotune=on " <>
            "brew_kp=#{Float.round(brew_kp, 3)}, steam_kp=#{Float.round(steam_kp, 3)}, " <>
            "brew_setpoint=#{Keyword.get(merged, :brew_setpoint, 101.0)}°C"
        )

        merged
        |> Keyword.put(:brew_kp, brew_kp)
        |> Keyword.put(:brew_ki, brew_ki)
        |> Keyword.put(:brew_kd, brew_kd)
        |> Keyword.put(:steam_kp, steam_kp)
        |> Keyword.put(:steam_ki, steam_ki)
        |> Keyword.put(:steam_kd, steam_kd)
        # Active gains start as brew gains (not in steam or brew-boost mode at boot)
        |> Keyword.put(:kp, brew_kp)
        |> Keyword.put(:ki, brew_ki)
        |> Keyword.put(:kd, brew_kd)
      else
        brew_kp = Keyword.get(merged, :brew_kp, 16.0)
        brew_ki = Keyword.get(merged, :brew_ki, 2.5)
        brew_kd = Keyword.get(merged, :brew_kd, 16.0)

        Logger.info(
          "Controller init: autotune=off " <>
            "brew_kp=#{Float.round(brew_kp, 3)}, " <>
            "brew_setpoint=#{Keyword.get(merged, :brew_setpoint, 101.0)}°C"
        )

        # Active gains = brew gains
        merged
        |> Keyword.put(:kp, brew_kp)
        |> Keyword.put(:ki, brew_ki)
        |> Keyword.put(:kd, brew_kd)
      end

    {history_queue, history_count} =
      case History.load() do
        {:ok, samples} ->
          trimmed = Enum.take(samples, -@history_max)

          {Enum.reduce(trimmed, :queue.new(), fn sample, q -> :queue.in(sample, q) end),
           length(trimmed)}

        _ ->
          {:queue.new(), 0}
      end

    Process.send_after(self(), :control_loop, 1000)

    {:ok,
     struct(
       State,
       merged ++
         [
           brew_switch_ref: brew_switch_ref,
           steam_switch_ref: steam_switch_ref,
           history: history_queue,
           history_count: history_count,
           history_flush_counter: 0
         ]
     )}
  end

  # --- Callbacks ---
  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:get_history, _from, state), do: {:reply, :queue.to_list(state.history), state}

  @impl true
  def handle_call({:set_config, new_config}, _, %State{} = state) do
    # Normalize map input to keyword list so downstream Keyword functions work correctly
    new_config = if is_map(new_config), do: Map.to_list(new_config), else: new_config

    # Determine effective autotune state for this call — the incoming config may be
    # enabling or disabling autotune, so we must use that value, not the old state.
    effective_autotune = Keyword.get(new_config, :autotune_enabled, state.autotune_enabled)

    # When autotune is enabled (now or after this call), reject attempts to set gain fields it owns
    new_config =
      if effective_autotune do
        {blocked, allowed} = Enum.split_with(new_config, fn {k, _} -> k in @autotune_managed_keys end)

        if blocked != [] do
          Logger.warning(
            "set_config: ignoring #{inspect(Enum.map(blocked, &elem(&1, 0)))} — managed by autotune. " <>
              "Disable autotune or call autotune_lambda/1 to update gains."
          )
        end

        allowed
      else
        new_config
      end

    # Keep brew anchor fields in sync when active gains are updated manually
    synced =
      new_config
      |> then(fn cfg ->
        if kp = cfg[:kp], do: Keyword.put_new(cfg, :brew_kp, kp), else: cfg
      end)
      |> then(fn cfg ->
        if ki = cfg[:ki], do: Keyword.put_new(cfg, :brew_ki, ki), else: cfg
      end)
      |> then(fn cfg ->
        if kd = cfg[:kd], do: Keyword.put_new(cfg, :brew_kd, kd), else: cfg
      end)

    new_state = struct(state, synced)

    # Persist the updated config (log failure but don't crash)
    save_map =
      @persisted_keys
      |> Enum.filter(&Keyword.has_key?(synced, &1))
      |> Enum.into(%{}, fn k -> {k, Map.get(new_state, k)} end)

    unless map_size(save_map) == 0 do
      case Config.save(save_map) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Config.save failed: #{inspect(reason)}")
      end
    end

    {:reply, new_state, new_state}
  end

  @impl true
  def handle_call({:autotune_lambda, _lambda_seconds}, _from, %State{autotune_enabled: false} = state) do
    {:reply, {:error, :autotune_disabled}, state}
  end

  @impl true
  def handle_call({:autotune_lambda, lambda_seconds}, _from, state) do
    {new_brew_kp, new_brew_ki, new_brew_kd} =
      calculate_lambda_gains(state.tau_seconds, lambda_seconds, state.process_gain)

    {new_steam_kp, new_steam_ki, new_steam_kd} =
      calculate_lambda_gains(state.tau_seconds, state.steam_lambda_seconds, state.process_gain)

    # Apply to active gains based on which mode we're in.
    # Brew-boost (1.2× Kp) must be preserved if a brew is in progress.
    {active_kp, active_ki, active_kd} =
      cond do
        state.steam_switch_state == :on ->
          {new_steam_kp, new_steam_ki, new_steam_kd}
        state.brew_switch_state == :on ->
          {new_brew_kp * state.brew_kp_multiplier, new_brew_ki, new_brew_kd}
        true ->
          {new_brew_kp, new_brew_ki, new_brew_kd}
      end

    Logger.info(
      "Re-tuning with lambda=#{lambda_seconds}s: " <>
        "brew_kp=#{Float.round(new_brew_kp, 3)}, steam_kp=#{Float.round(new_steam_kp, 3)}"
    )

    new_state =
      struct(state,
        kp: active_kp,
        ki: active_ki,
        kd: active_kd,
        brew_kp: new_brew_kp,
        brew_ki: new_brew_ki,
        brew_kd: new_brew_kd,
        steam_kp: new_steam_kp,
        steam_ki: new_steam_ki,
        steam_kd: new_steam_kd,
        lambda_seconds: lambda_seconds
      )

    Config.save(%{
      brew_kp: new_brew_kp,
      brew_ki: new_brew_ki,
      brew_kd: new_brew_kd,
      steam_kp: new_steam_kp,
      steam_ki: new_steam_ki,
      steam_kd: new_steam_kd,
      lambda_seconds: lambda_seconds
    })
    |> case do
      :ok -> :ok
      {:error, reason} -> Logger.error("Config.save after autotune failed: #{inspect(reason)}")
    end

    {:reply, {:ok, {new_brew_kp, new_brew_ki, new_brew_kd}}, new_state}
  end

  @impl true
  def handle_cast(:enable_pid, %State{} = state) do
    Logger.info("Enabling PID")

    case state.brew_switch_state do
      :on -> {:noreply, brew_pid_state(state)}
      :off -> {:noreply, struct(state, mode: :pid, initialized: false)}
    end
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
        "Restore setpoint to #{state.brew_setpoint}°C and gains to brew baseline"
    )

    normal_state =
      struct(state,
        brew_switch_state: :off,
        mode: :pid,
        initialized: false,
        setpoint: state.brew_setpoint,
        kp: state.brew_kp,
        ki: state.brew_ki,
        kd: state.brew_kd,
        error_sum: 0.0,
        last_error: 0
      )

    {:noreply, normal_state}
  end

  @impl true
  def handle_info({:circuits_gpio, @brew_switch_pin, _timestamp, 0}, state) do
    Logger.info(
      "Brew switch ON - activating PID with feedforward compensation. " <>
        "Boost setpoint by #{state.brew_cooling_compensation_c}°C and Kp by #{state.brew_kp_multiplier}×"
    )

    # Enter PID mode (not PWM) with boosted setpoint and Kp to compensate for measured cooling
    {:noreply, brew_pid_state(state)}
  end

  @impl true
  def handle_info({:circuits_gpio, @steam_switch_pin, _timestamp, 1}, state) do
    Logger.info("Steam switch OFF - restoring brew gains and setpoint #{state.brew_setpoint}°C")

    {:noreply,
     struct(state,
       steam_switch_state: :off,
       setpoint: state.brew_setpoint,
       kp: state.brew_kp,
       ki: state.brew_ki,
       kd: state.brew_kd,
       initialized: false
     )}
  end

  @impl true
  def handle_info({:circuits_gpio, @steam_switch_pin, _timestamp, 0}, state) do
    Logger.info("Steam switch ON - switching to steam gains and setpoint #{state.steam_setpoint}°C")

    {:noreply,
     struct(state,
       steam_switch_state: :on,
       setpoint: state.steam_setpoint,
       kp: state.steam_kp,
       ki: state.steam_ki,
       kd: state.steam_kd,
       initialized: false
     )}
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
        # Hold integral constant when saturated
        state.error_sum
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

    state = record_sample(state, reading, output)

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
    flush_history(state)
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

  defp record_sample(state, reading, output) do
    flush_counter = state.history_flush_counter + 1

    sample = %{
      t: System.os_time(:millisecond),
      temp: reading * 1.0,
      sp: state.setpoint * 1.0,
      out: output,
      mode: state.mode
    }

    {q, count} =
      if state.history_count >= @history_max do
        {{:value, _oldest}, new_q} = :queue.out(state.history)
        {new_q, state.history_count}
      else
        {state.history, state.history_count + 1}
      end

    new_state =
      struct(state,
        history: :queue.in(sample, q),
        history_count: count,
        history_flush_counter: rem(flush_counter, @history_flush_every)
      )

    if flush_counter >= @history_flush_every do
      flush_history(new_state)
    else
      new_state
    end
  end

  defp flush_history(state) do
    case History.save(:queue.to_list(state.history)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("History.save failed: #{inspect(reason)}")
    end

    state
  end

  defp brew_pid_state(state) do
    struct(state,
      brew_switch_state: :on,
      mode: :pid,
      initialized: false,
      setpoint: state.brew_setpoint + state.brew_cooling_compensation_c,
      kp: state.brew_kp * state.brew_kp_multiplier,
      ki: state.brew_ki,
      kd: state.brew_kd,
      error_sum: 0.0,
      last_error: 0
    )
  end

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
