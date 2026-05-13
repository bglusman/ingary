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
        http_child(host, port)
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: ElixirIngary.Supervisor]
    result = Supervisor.start_link(children, opts)

    if serve_http?() do
      Logger.info("elixir-ingary mock listening on http://#{:inet.ntoa(host)}:#{port}")
    end

    result
  end

  defp http_child(host, port) do
    if serve_http?() do
      {Plug.Cowboy, scheme: :http, plug: ElixirIngary.Router, options: [ip: host, port: port]}
    end
  end

  defp serve_http?, do: Application.get_env(:elixir_ingary, :serve_http, true)

  defp bind do
    raw = System.get_env("INGARY_BIND", "127.0.0.1:8787")
    [host, port] = String.split(raw, ":", parts: 2)
    {:ok, parsed_host} = host |> String.to_charlist() |> :inet.parse_address()
    {parsed_host, String.to_integer(port)}
  end
end
