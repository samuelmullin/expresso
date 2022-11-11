defmodule ExpressoUiWeb.ControllerLive do
  use ExpressoUiWeb, :live_view

  require Logger

  @max_readings 1800

  def render(assigns) do
    ~H"""
    <div class="wrapper">
      <.live_component module={ExpressoUiWeb.ReadingChartComponent} id="reading-chart" data_set={@data_set} />
      <div class="box controller-settings-box">
        <div class="controller-settings-label-box">
         <div class="controller-settings-label"> KP: </div>
         <div class="controller-settings-label"> KI: </div>
         <div class="controller-settings-label"> KD: </div>
         <div class="controller-settings-label"> Cycle(ms): </div>
         <div class="controller-settings-label"> Brew(c): </div>
         <div class="controller-settings-label"> Steam(c): </div>
         <div class="controller-settings-label"> Max Integral: </div>
         <div class="controller-settings-label"> Min Output: </div>
         <div class="controller-settings-label"> Max Output: </div>
        </div>
        <div class="controller-settings-inputs-box">
          <%= f = form_for :controller_config, "#", id: "controller_config_form", class: "form-inline", phx_change: "controller_settings_validate", phx_submit: "controller_settings_update" %>
          <%= number_input f, :kp, [class: "controller-config-input", value: @kp, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :ki, [class: "controller-config-input", value: @ki, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :kd, [class: "controller-config-input", value: @kd, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :cycle_ms, [class: "controller-config-input", value: @cycle_ms, step: "1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :brew_setpoint, [class: "controller-config-input", value: @brew_setpoint, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :steam_setpoint, [class: "controller-config-input", value: @steam_setpoint, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :max_integral, [class: "controller-config-input", value: @max_integral, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :min_output, [class: "controller-config-input", value: @min_output, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= number_input f, :max_output, [class: "controller-config-input", value: @max_output, step: "0.1"] |> maybe_disable(@settings_locked) %>
          <%= select f, :mode, [class: "controller-config-input", value: @mode] |> maybe_disable(@settings_locked) %>
          <%= case @settings_locked do %>
          <% true -> %>
            <button type="button" id="settings_edit" class="controller-config-button", phx-click="edit">Edit</button>
          <% false -> %>
              <button type="submit" class="controller-config-button">Save</button>
              <button type="button" id="settings_cancel" class="controller-config-button", phx-click="cancel_edit">Cancel</button>
        <% end %>

        </div>
        <div class="controller-settings-buttons-box">

        </div>
      </div>
    </div>
    """
  end

  def maybe_disable(attributes, true), do: Keyword.put(attributes, :disabled, 1)
  def maybe_disable(attributes, false), do: attributes

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(1000, self(), :tick)
    controller_state = controller().get_state()
    config = [
      kp: controller_state.kp,
      ki: controller_state.ki,
      kd: controller_state.kd,
      cycle_ms: controller_state.cycle_ms,
      setpoint: controller_state.setpoint,
      brew_setpoint: controller_state.brew_setpoint,
      steam_setpoint: controller_state.steam_setpoint,
      mode: controller_state.mode,
      min_output: controller_state.min_output,
      max_output: controller_state.max_output,
      max_integral: controller_state.max_integral,
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

  def handle_event("controller_settings_validate", %{"controller_config" => controller_config}, socket) do
    Logger.info("#{inspect(controller_config)}")
    {:noreply, assign(socket, controller_config: controller_config)}
  end

  def handle_event("controller_settings_update", %{"controller_config" => controller_config}, socket) do
    {kp, _} = Map.get(controller_config, "kp") |> Float.parse()
    {ki, _} = Map.get(controller_config, "ki") |> Float.parse()
    {kd, _} = Map.get(controller_config, "kd") |> Float.parse()
    {cycle_ms, _} = Map.get(controller_config, "cycle_ms") |> Integer.parse()
    {brew_setpoint, _} = Map.get(controller_config, "brew_setpoint") |> Float.parse()
    {steam_setpoint, _} = Map.get(controller_config, "steam_setpoint") |> Float.parse()
    mode = Map.get(controller_config, "mode")
    {max_integral, _} = Map.get(controller_config, "max_integral") |> Float.parse()
    {min_output, _} = Map.get(controller_config, "min_output") |> Float.parse()
    {max_output, _} = Map.get(controller_config, "max_output") |> Float.parse()


    config = controller().set_config(%{
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
    state = controller().get_state()
    [%{timestamp: NaiveDateTime.utc_now(), reading: state.reading, setpoint: state.setpoint} | data_set] |> Enum.take(@max_readings)
  end

  def controller() do
    Application.get_env(:expresso_ui, :controller_module, ExpressoUi.StubController)
  end
end
