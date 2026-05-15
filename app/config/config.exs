import Config

config :wardwright, serve_http: true

config :wardwright, WardwrightWeb.Endpoint,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [html: WardwrightWeb.ErrorHTML, json: WardwrightWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Wardwright.PubSub,
  live_view: [signing_salt: "wardwright-policy-projection-v1"]

env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end
