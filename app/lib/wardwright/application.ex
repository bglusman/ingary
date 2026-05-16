defmodule Wardwright.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    maybe_handle_standalone_command()

    {host, port} = bind()

    children =
      [
        Wardwright.ReceiptStore,
        Wardwright.PolicyScenarioStore,
        {DynamicSupervisor,
         strategy: :one_for_one, name: Wardwright.PolicyCache.SessionSupervisor},
        Wardwright.PolicyCache,
        Wardwright.Policy.AlertDelivery,
        Wardwright.ProviderRuntime,
        {Task.Supervisor, name: Wardwright.ProviderRuntime.TaskSupervisor},
        {Phoenix.PubSub, name: Wardwright.PubSub},
        {Registry, keys: :unique, name: Wardwright.Runtime.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Wardwright.Runtime.ModelSupervisor},
        {DynamicSupervisor, strategy: :one_for_one, name: Wardwright.Runtime.SessionSupervisor},
        Hermes.Server.Registry,
        {WardwrightWeb.MCPServer, transport: {:streamable_http, start: true}},
        endpoint_child(host, port)
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Wardwright.Supervisor]
    result = Supervisor.start_link(children, opts)

    if serve_http?() do
      Logger.info("wardwright app listening on http://#{:inet.ntoa(host)}:#{port}")
    end

    result
  end

  defp endpoint_child(host, port) do
    if serve_http?() do
      endpoint_config =
        :wardwright
        |> Application.get_env(WardwrightWeb.Endpoint, [])
        |> Keyword.merge(
          http: [ip: host, port: port],
          server: true,
          secret_key_base: secret_key_base()
        )

      Application.put_env(:wardwright, WardwrightWeb.Endpoint, endpoint_config)

      WardwrightWeb.Endpoint
    end
  end

  defp secret_key_base do
    System.get_env("WARDWRIGHT_SECRET_KEY_BASE") ||
      if Application.get_env(:wardwright, :require_secret_key_base, false) do
        raise """
        WARDWRIGHT_SECRET_KEY_BASE is required when running Wardwright as a packaged service.
        Generate one with: openssl rand -base64 64
        """
      else
        Base.encode64(:crypto.strong_rand_bytes(64))
      end
  end

  defp serve_http?, do: Application.get_env(:wardwright, :serve_http, true)

  defp bind do
    raw = System.get_env("WARDWRIGHT_BIND", "127.0.0.1:8787")
    [host, port] = String.split(raw, ":", parts: 2)
    {:ok, parsed_host} = host |> String.to_charlist() |> :inet.parse_address()
    {parsed_host, String.to_integer(port)}
  end

  defp maybe_handle_standalone_command do
    case argv() do
      ["--version" | _] ->
        IO.puts(version())
        System.halt(0)

      ["version" | _] ->
        IO.puts(version())
        System.halt(0)

      ["--help" | _] ->
        IO.puts("""
        wardwright #{version()}

        Usage:
          wardwright              Start the Wardwright HTTP service
          wardwright --version    Print the packaged app version

        Runtime environment:
          WARDWRIGHT_BIND             Host and port, default 127.0.0.1:8787
          WARDWRIGHT_SECRET_KEY_BASE  Stable Phoenix signing secret for services
          WARDWRIGHT_ADMIN_TOKEN      Optional token for protected local APIs
        """)

        System.halt(0)

      _ ->
        :ok
    end
  end

  defp argv do
    if System.get_env("__BURRITO") do
      :init.get_plain_arguments() |> Enum.map(&to_string/1)
    else
      System.argv()
    end
  end

  defp version do
    :wardwright
    |> Application.spec(:vsn)
    |> to_string()
  end
end
