defmodule ExpressoUiWeb.PIDLive do
  use ExpressoUiWeb, :live_view

  require Logger

  @max_readings 1800

  def render(assigns) do
    ~H"""
    <div class="wrapper">
      <.live_component module={ExpressoUiWeb.ReadingChartComponent} id="reading-chart" data_set={@data_set} />
      <div class="box pid-settings-box">
        <div class="pid-settings-label-box">
         <div class="pid-settings-label"> KP: </div>
         <div class="pid-settings-label"> KI: </div>
         <div class="pid-settings-label"> KD: </div>
         <div class="pid-settings-label"> Cycle(ms): </div>
         <div class="pid-settings-label"> Brew(c): </div>
         <div class="pid-settings-label"> Steam(c): </div>
         <div class="pid-settings-label"> Max Integral: </div>
         <div class="pid-settings-label"> Min Output: </div>
         <div class="pid-settings-label"> Max Output: </div>
        </div>
        <div class="pid-settings-inputs-box">
          <%= f = form_for :pid_config, "#", id: "pid_config_form", class: "form-inline", phx_change: "pid_settings_validate", phx_submit: "pid_settings_update" %>
          <%= number_input f, :kp, [class: "pid-config-input", value: @kp, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :ki, [class: "pid-config-input", value: @ki, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :kd, [class: "pid-config-input", value: @kd, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :cycle_ms, [class: "pid-config-input", value: @cycle_ms, step: "1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :brew_setpoint, [class: "pid-config-input", value: @brew_setpoint, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :steam_setpoint, [class: "pid-config-input", value: @steam_setpoint, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :max_integral, [class: "pid-config-input", value: @max_integral, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :min_output, [class: "pid-config-input", value: @min_output, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :max_output, [class: "pid-config-input", value: @max_output, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= select f, :mode, [class: "pid-config-input", value: @mode] |> maybe_disable(@settings_locked) %>
          <%= case @settings_locked do %>
          <% true -> %>
            <button type="button" id="settings_edit" class="pid-config-button", phx-click="edit">Edit</button>
          <% false -> %>
              <button type="submit" class="pid-config-button">Save</button>
              <button type="button" id="settings_cancel" class="pid-config-button", phx-click="cancel_edit">Cancel</button>
        <% end %>

        </div>
        <div class="pid-settings-buttons-box">

        </div>
      </div>
    </div>
    """
  end

  def maybe_disable(attributes, true), do: Keyword.put(attributes, :disabled, 1)
  def maybe_disable(attributes, false), do: attributes

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(1000, self(), :tick)
    pid_state = pid().get_state()
    config = [
      kp: pid_state.kp,
      ki: pid_state.ki,
      kd: pid_state.kd,
      cycle_ms: pid_state.cycle_ms,
      setpoint: pid_state.setpoint,
      brew_setpoint: pid_state.brew_setpoint,
      steam_setpoint: pid_state.steam_setpoint,
      mode: pid_state.mode,
      min_output: pid_state.min_output,
      max_output: pid_state.max_output,
      max_integral: pid_state.max_integral,
      data_set: [],
      reading_plot: "",
      settings_locked: true
    ]
    {:ok, assign(socket, config)}
  end

  def handle_info(:tick, socket) do
    data_set = update_data_set(socket.assigns.data_set)
    {:noreply, assign(socket, [data_set: data_set])}
  end

  def handle_event("edit", _, socket) do
    {:noreply, assign(socket, settings_locked: false)}
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, assign(socket, settings_locked: true)}
  end

  def handle_event("pid_settings_validate", %{"pid_config" => pid_config}, socket) do
    Logger.info("#{inspect(pid_config)}")
    {:noreply, assign(socket, pid_config: pid_config)}
  end

  def handle_event("pid_settings_update", %{"pid_config" => pid_config}, socket) do
    {kp, _} = Map.get(pid_config, "kp") |> Float.parse()
    {ki, _} = Map.get(pid_config, "ki") |> Float.parse()
    {kd, _} = Map.get(pid_config, "kd") |> Float.parse()
    {cycle_ms, _} = Map.get(pid_config, "cycle_ms") |> Integer.parse()
    {brew_setpoint, _} = Map.get(pid_config, "brew_setpoint") |> Float.parse()
    {steam_setpoint, _} = Map.get(pid_config, "steam_setpoint") |> Float.parse()
    mode = Map.get(pid_config, "mode")
    {max_integral, _} = Map.get(pid_config, "max_integral") |> Float.parse()
    {min_output, _} = Map.get(pid_config, "min_output") |> Float.parse()
    {max_output, _} = Map.get(pid_config, "max_output") |> Float.parse()


    config = pid().set_config(%{
      kp: kp,
      ki: ki,
      kd: kd,
      cycle_ms: cycle_ms,
      brew_setpoint: brew_setpoint,
      steam_setpoint: steam_setpoint,
      mode: mode,
      min_output: min_output,
      max_output: max_output,
      max_integral: max_integral
    })

    Logger.info("#{inspect(config)}")

    updated_config = [
      kp: config.kp,
      ki: config.ki,
      kd: config.kd,
      cycle_ms: config.cycle_ms,
      brew_setpoint: config.brew_setpoint,
      steam_setpoint: config.steam_setpoint,
      mode: mode,
      min_output: min_output,
      max_output: max_output,
      max_integral: max_integral,
      settings_locked: true
    ]

    {:noreply, assign(socket, updated_config) |> IO.inspect()}
  end

  defp update_data_set(data_set) do
    state = pid().get_state()
    [%{timestamp: NaiveDateTime.utc_now(), reading: state.reading, setpoint: state.setpoint} | data_set] |> Enum.take(@max_readings)
  end

  def pid() do
    Application.get_env(:expresso_ui, :pid_controller, ExpressoUi.StubPID)
  end
end
