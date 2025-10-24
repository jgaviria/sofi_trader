defmodule SofiTraderWeb.PageController do
  use SofiTraderWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
