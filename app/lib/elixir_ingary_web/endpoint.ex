defmodule ElixirIngaryWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :elixir_ingary

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.Static,
    at: "/",
    from: :elixir_ingary,
    gzip: false,
    only: ~w(assets favicon.ico robots.txt)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session,
    store: :cookie,
    key: "_ingary_key",
    signing_salt: "policy projection"
  )

  plug(ElixirIngaryWeb.Router)
end
