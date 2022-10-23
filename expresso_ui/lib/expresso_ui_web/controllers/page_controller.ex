defmodule ExpressoUiWeb.PageController do
  use ExpressoUiWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
