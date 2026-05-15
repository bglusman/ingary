defmodule ElixirIngary.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    {host, port} = bind()

    children =
      [
        ElixirIngary.ReceiptStore,
        ElixirIngary.PolicyCache,
        {Phoenix.PubSub, name: ElixirIngary.PubSub},
        endpoint_child(host, port)
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: ElixirIngary.Supervisor]
    result = Supervisor.start_link(children, opts)

    if serve_http?() do
      Logger.info("elixir-ingary mock listening on http://#{:inet.ntoa(host)}:#{port}")
    end

    result
  end

  defp endpoint_child(host, port) do
    if serve_http?() do
      endpoint_config =
        :elixir_ingary
        |> Application.get_env(ElixirIngaryWeb.Endpoint, [])
        |> Keyword.merge(
          http: [ip: host, port: port],
          server: true,
          secret_key_base: secret_key_base()
        )

      Application.put_env(:elixir_ingary, ElixirIngaryWeb.Endpoint, endpoint_config)

      ElixirIngaryWeb.Endpoint
    end
  end

  defp secret_key_base do
    System.get_env("INGARY_SECRET_KEY_BASE") ||
      Base.encode64(:crypto.strong_rand_bytes(64))
  end

  defp serve_http?, do: Application.get_env(:elixir_ingary, :serve_http, true)

  defp bind do
    raw = System.get_env("INGARY_BIND", "127.0.0.1:8787")
    [host, port] = String.split(raw, ":", parts: 2)
    {:ok, parsed_host} = host |> String.to_charlist() |> :inet.parse_address()
    {parsed_host, String.to_integer(port)}
  end
end
