defmodule ExpressoUiWeb.ControllerLive do
  use ExpressoUiWeb, :live_view

  require Logger

  def render(assigns) do
    ~H"""
    <div class="dashboard">

      <!-- Status bar -->
      <div class="status-bar">
        <div class="status-item status-item--large">
          <span class="status-value"><%= Float.round(@temp * 1.0, 1) %>°C</span>
          <span class="status-label">temp</span>
        </div>
        <div class="status-item">
          <span class="status-value"><%= Float.round(@setpoint * 1.0, 1) %>°C</span>
          <span class="status-label">setpoint</span>
        </div>
        <div class="status-item">
          <span class="status-value"><%= @output %>%</span>
          <span class="status-label">output</span>
        </div>
        <div class="status-item">
          <span class={"mode-badge mode-badge--#{@mode}"}><%= @mode %></span>
          <span class="status-label">mode</span>
        </div>
        <div class="status-item">
          <span class={"switch-dot #{if @brew_switch == :on, do: "switch-dot--on"}"}></span>
          <span class="status-label">brew switch</span>
        </div>
        <div class="status-item">
          <span class={"switch-dot #{if @steam_switch == :on, do: "switch-dot--on"}"}></span>
          <span class="status-label">steam switch</span>
        </div>
      </div>

      <!-- Chart -->
      <.live_component module={ExpressoUiWeb.ReadingChartComponent} id="reading-chart" history={@history} />

      <!-- Settings -->
      <div class="box settings-box">
        <%= if @save_result do %>
          <div class={"save-feedback save-feedback--#{elem(@save_result, 0)}"}>
            <%= elem(@save_result, 1) %>
          </div>
        <% end %>

        <%= form_for :cfg, "#", [id: "settings_form", phx_submit: "save", phx_change: "validate"], fn f -> %>
          <div class="settings-grid">

            <div class="settings-section">
              <h3 class="settings-section-title">Setpoints</h3>
              <label>Brew (°C)
                <%= number_input f, :brew_setpoint, value: @brew_setpoint, step: "0.1", class: "settings-input", disabled: @settings_locked %>
              </label>
              <label>Steam (°C)
                <%= number_input f, :steam_setpoint, value: @steam_setpoint, step: "0.1", class: "settings-input", disabled: @settings_locked %>
              </label>
            </div>

            <div class="settings-section">
              <h3 class="settings-section-title">Gains</h3>
              <label class="settings-checkbox-label">
                <%= checkbox f, :autotune_enabled, value: @autotune_enabled, class: "settings-checkbox", disabled: @settings_locked %>
                Autotune
              </label>
              <%= if @autotune_enabled do %>
                <div class="gains-readonly">
                  <div class="gain-row"><span>Brew KP</span><span><%= Float.round(@brew_kp * 1.0, 4) %></span></div>
                  <div class="gain-row"><span>Brew KI</span><span><%= Float.round(@brew_ki * 1.0, 5) %></span></div>
                  <div class="gain-row"><span>Brew KD</span><span><%= Float.round(@brew_kd * 1.0, 3) %></span></div>
                  <div class="gain-row"><span>Steam KP</span><span><%= Float.round(@steam_kp * 1.0, 4) %></span></div>
                  <div class="gain-row"><span>Steam KI</span><span><%= Float.round(@steam_ki * 1.0, 5) %></span></div>
                  <div class="gain-row"><span>Steam KD</span><span><%= Float.round(@steam_kd * 1.0, 3) %></span></div>
                </div>
              <% else %>
                <label>Brew KP <%= number_input f, :brew_kp, value: @brew_kp, step: "0.0001", class: "settings-input", disabled: @settings_locked %></label>
                <label>Brew KI <%= number_input f, :brew_ki, value: @brew_ki, step: "0.00001", class: "settings-input", disabled: @settings_locked %></label>
                <label>Brew KD <%= number_input f, :brew_kd, value: @brew_kd, step: "0.001", class: "settings-input", disabled: @settings_locked %></label>
                <label>Steam KP <%= number_input f, :steam_kp, value: @steam_kp, step: "0.0001", class: "settings-input", disabled: @settings_locked %></label>
                <label>Steam KI <%= number_input f, :steam_ki, value: @steam_ki, step: "0.00001", class: "settings-input", disabled: @settings_locked %></label>
                <label>Steam KD <%= number_input f, :steam_kd, value: @steam_kd, step: "0.001", class: "settings-input", disabled: @settings_locked %></label>
              <% end %>
            </div>

            <div class="settings-section">
              <h3 class="settings-section-title">PID</h3>
              <label>Cycle (ms)
                <%= number_input f, :cycle_ms, value: @cycle_ms, step: "1", class: "settings-input", disabled: @settings_locked %>
              </label>
              <label>Max Integral
                <%= number_input f, :max_integral, value: @max_integral, step: "0.1", class: "settings-input", disabled: @settings_locked %>
              </label>
              <label>Min Output
                <%= number_input f, :min_output, value: @min_output, step: "1", class: "settings-input", disabled: @settings_locked %>
              </label>
              <label>Max Output
                <%= number_input f, :max_output, value: @max_output, step: "1", class: "settings-input", disabled: @settings_locked %>
              </label>
            </div>

          </div>

          <div class="settings-actions">
            <%= if @settings_locked do %>
              <button type="button" phx-click="edit" class="btn">Edit</button>
            <% else %>
              <button type="submit" class="btn btn-primary">Save</button>
              <button type="button" phx-click="cancel" class="btn">Cancel</button>
            <% end %>
          </div>
        <% end %>
      </div>

    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :tick)
      state = controller().get_state()
      history = controller().get_history()
      {:ok, assign(socket, build_assigns(state, history, true, nil, 0))}
    else
      {:ok, assign(socket, build_assigns(controller().get_state(), [], true, nil, 0))}
    end
  end

  def handle_info(:tick, socket) do
    state = controller().get_state()
    history = controller().get_history()

    {save_result, save_ticks} =
      case socket.assigns.save_result do
        nil -> {nil, 0}
        {:error, _} = r -> {r, 0}
        {:ok, _} = r ->
          ticks = socket.assigns.save_ticks + 1
          if ticks > 4, do: {nil, 0}, else: {r, ticks}
      end

    {:noreply,
     assign(socket,
       temp: state.reading,
       setpoint: state.setpoint,
       output: state.last_output,
       mode: state.mode,
       brew_switch: state.brew_switch_state,
       steam_switch: state.steam_switch_state,
       brew_kp: state.brew_kp,
       brew_ki: state.brew_ki,
       brew_kd: state.brew_kd,
       steam_kp: state.steam_kp,
       steam_ki: state.steam_ki,
       steam_kd: state.steam_kd,
       autotune_enabled: state.autotune_enabled,
       history: history,
       save_result: save_result,
       save_ticks: save_ticks
     )}
  end

  def handle_event("edit", _, socket) do
    {:noreply, assign(socket, settings_locked: false, save_result: nil, save_ticks: 0)}
  end

  def handle_event("cancel", _, socket) do
    state = controller().get_state()
    {:noreply, assign(socket, build_assigns(state, socket.assigns.history, true, nil, 0))}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, assign(socket, save_result: nil, save_ticks: 0)}
  end

  def handle_event("save", %{"cfg" => cfg}, socket) do
    autotune_enabled = cfg["autotune_enabled"] in ["true", "on"]

    base_parse =
      with {brew_setpoint, _} <- Float.parse(cfg["brew_setpoint"] || ""),
           {steam_setpoint, _} <- Float.parse(cfg["steam_setpoint"] || ""),
           {cycle_ms, _} <- Integer.parse(cfg["cycle_ms"] || ""),
           {max_integral, _} <- Float.parse(cfg["max_integral"] || ""),
           {min_output, _} <- Float.parse(cfg["min_output"] || ""),
           {max_output, _} <- Float.parse(cfg["max_output"] || "") do
        {:ok,
         [
           brew_setpoint: brew_setpoint,
           steam_setpoint: steam_setpoint,
           cycle_ms: cycle_ms,
           max_integral: max_integral,
           min_output: min_output,
           max_output: max_output,
           autotune_enabled: autotune_enabled
         ]}
      else
        _ -> :error
      end

    gain_parse =
      if not autotune_enabled do
        with {brew_kp, _} <- Float.parse(cfg["brew_kp"] || ""),
             {brew_ki, _} <- Float.parse(cfg["brew_ki"] || ""),
             {brew_kd, _} <- Float.parse(cfg["brew_kd"] || ""),
             {steam_kp, _} <- Float.parse(cfg["steam_kp"] || ""),
             {steam_ki, _} <- Float.parse(cfg["steam_ki"] || ""),
             {steam_kd, _} <- Float.parse(cfg["steam_kd"] || "") do
          {:ok,
           [
             brew_kp: brew_kp,
             brew_ki: brew_ki,
             brew_kd: brew_kd,
             steam_kp: steam_kp,
             steam_ki: steam_ki,
             steam_kd: steam_kd
           ]}
        else
          _ -> :error
        end
      else
        {:ok, []}
      end

    case {base_parse, gain_parse} do
      {{:ok, base}, {:ok, gains}} ->
        new_state = controller().set_config(base ++ gains)
        {:noreply, assign(socket, build_assigns(new_state, socket.assigns.history, true, {:ok, "Saved."}, 0))}

      _ ->
        {:noreply, assign(socket, settings_locked: false, save_result: {:error, "Invalid values."}, save_ticks: 0)}
    end
  end

  defp build_assigns(state, history, locked, save_result, save_ticks) do
    [
      temp: state.reading,
      setpoint: state.setpoint,
      output: state.last_output,
      mode: state.mode,
      brew_switch: state.brew_switch_state,
      steam_switch: state.steam_switch_state,
      brew_setpoint: state.brew_setpoint,
      steam_setpoint: state.steam_setpoint,
      autotune_enabled: state.autotune_enabled,
      brew_kp: state.brew_kp,
      brew_ki: state.brew_ki,
      brew_kd: state.brew_kd,
      steam_kp: state.steam_kp,
      steam_ki: state.steam_ki,
      steam_kd: state.steam_kd,
      cycle_ms: state.cycle_ms,
      max_integral: state.max_integral,
      min_output: state.min_output,
      max_output: state.max_output,
      history: history,
      settings_locked: locked,
      save_result: save_result,
      save_ticks: save_ticks
    ]
  end

  defp controller do
    Application.get_env(:expresso_ui, :controller_module, ExpressoUi.StubController)
  end
end
