defmodule ExpressoUi.StubController do
def set_config(config), do: config
def get_state(), do: %{
  temp: 93,
  kp: 25,
  ki: 0,
  kd: 0,
  cycle_ms: 1000,
  setpoint: 94,
  brew_setpoint: 94,
  steam_setpoint: 140,
  data_set: [],
  temp_plot: "",
  settings_locked: true
}
end
