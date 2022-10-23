defmodule ExpressoUiWeb.ReadingChartComponent do
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"""
    <div class="box chart-box">
      <%= @reading_plot %>
    </div>
    """
  end

  def mount(socket) do
    {:ok, assign(socket, reading_plot: "")}
  end

  def update(%{data_set: []}, socket),
    do: update(%{data_set: [%{timestamp: 0, reading: 0, setpoint: 0}]}, socket)
  def update(%{data_set: data_set}, socket) do
    chart = data_set
    |> Contex.Dataset.new()
    |> Contex.LinePlot.new(
      mapping: %{x_col: :timestamp, y_cols: [:reading, :setpoint]}
    )

    plot = Contex.Plot.new(400, 300, chart)
    |> Contex.Plot.to_svg()

    {:ok, assign(socket, reading_plot: plot)}
  end
end
