defmodule WardwrightWeb.Router do
  @moduledoc false

  use Phoenix.Router, helpers: false
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {WardwrightWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", WardwrightWeb do
    pipe_through(:browser)

    live("/", PolicyProjectionLive, :index)
    live("/policies", PolicyProjectionLive, :index)
    live("/policies/:pattern/:mode", PolicyProjectionLive, :index)
  end

  scope "/" do
    pipe_through(:api)

    forward("/", Wardwright.Router)
  end
end
