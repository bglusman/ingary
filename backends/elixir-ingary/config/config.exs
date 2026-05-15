import Config

config :elixir_ingary, serve_http: true

config :elixir_ingary, ElixirIngaryWeb.Endpoint,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: ElixirIngaryWeb.ErrorHTML, json: ElixirIngaryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirIngary.PubSub,
  live_view: [signing_salt: "ingary-policy-projection-v1"]

env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end
