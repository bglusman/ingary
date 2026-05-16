defmodule WardwrightWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :wardwright

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.Static,
    at: "/",
    from: :wardwright,
    gzip: false,
    only: ~w(assets favicon.ico robots.txt)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.min.js)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.min.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session,
    store: :cookie,
    key: "_wardwright_key",
    signing_salt: "policy projection"
  )

  plug(WardwrightWeb.Router)
end
