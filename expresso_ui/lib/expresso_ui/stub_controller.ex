defmodule ExpressoUi.StubController do
  @state %{
    reading: 93.4,
    setpoint: 93.5,
    brew_setpoint: 93.5,
    steam_setpoint: 155.0,
    mode: :disabled,
    last_output: 0,
    brew_switch_state: :off,
    steam_switch_state: :off,
    autotune_enabled: true,
    brew_kp: 0.8182,
    brew_ki: 0.01485,
    brew_kd: 0.0,
    steam_kp: 0.5357,
    steam_ki: 0.00893,
    steam_kd: 0.0,
    lambda_seconds: 10.0,
    steam_lambda_seconds: 15.0,
    tau_seconds: 45.0,
    process_gain: 1.0,
    brew_cooling_compensation_c: 2.7,
    brew_kp_multiplier: 1.2,
    cycle_ms: 1000,
    min_output: 0,
    max_output: 100,
    max_integral: 20.0
  }

  def get_state, do: @state

  def get_history, do: []

  def set_config(config) do
    config = if is_map(config), do: config, else: Enum.into(config, %{})
    Map.merge(@state, config)
  end

  def autotune_lambda(_lambda_seconds), do: {:ok, {@state.brew_kp, @state.brew_ki, @state.brew_kd}}
end
