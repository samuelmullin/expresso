defmodule ExpressoUiWeb.ReadingChartComponent do
  use Phoenix.LiveComponent

  @empty [%{t: 0, temp: 0.0, sp: 0.0}]

  def render(assigns) do
    ~H"""
    <div class="box chart-box">
      <%= @svg %>
    </div>
    """
  end

  def mount(socket) do
    {:ok, assign(socket, svg: "")}
  end

  def update(%{history: []}, socket), do: update(%{history: @empty}, socket)
  def update(%{history: history}, socket) do
    dataset =
      history
      |> Enum.map(fn s -> %{t: Map.get(s, :t, 0), temp: Map.get(s, :temp, 0.0), sp: Map.get(s, :sp, 0.0)} end)
      |> Contex.Dataset.new()

    chart = Contex.LinePlot.new(dataset, mapping: %{x_col: :t, y_cols: [:temp, :sp]})
    svg = Contex.Plot.new(500, 250, chart) |> Contex.Plot.to_svg()

    {:ok, assign(socket, svg: svg)}
  end
end
