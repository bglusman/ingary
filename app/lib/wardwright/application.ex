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
          url: [host: endpoint_host(host), port: port],
          check_origin: check_origins(host, port),
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

  defp endpoint_host(host) do
    case :inet.ntoa(host) |> to_string() do
      "0.0.0.0" -> "localhost"
      "::" -> "localhost"
      host -> host
    end
  end

  defp check_origins(host, port) do
    configured_origins =
      "WARDWRIGHT_ALLOWED_ORIGINS"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    hosts =
      ["localhost", "127.0.0.1", endpoint_host(host)] ++
        if wildcard_host?(host), do: local_interface_hosts(), else: []

    hosts
    |> Enum.uniq()
    |> Enum.flat_map(fn origin_host ->
      ["http://#{origin_host}:#{port}", "//#{origin_host}:#{port}"]
    end)
    |> Kernel.++(configured_origins)
    |> Enum.uniq()
  end

  defp wildcard_host?({0, 0, 0, 0}), do: true
  defp wildcard_host?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp wildcard_host?(_host), do: false

  defp local_interface_hosts do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> Enum.flat_map(fn {_name, options} -> Keyword.get_values(options, :addr) end)
        |> Enum.filter(&match?({_, _, _, _}, &1))
        |> Enum.map(&(:inet.ntoa(&1) |> to_string()))

      {:error, _reason} ->
        []
    end
  end

  defp bind do
    raw = System.get_env("WARDWRIGHT_BIND", "127.0.0.1:8787")
    [host, port] = String.split(raw, ":", parts: 2)
    {:ok, parsed_host} = host |> String.to_charlist() |> :inet.parse_address()
    {parsed_host, String.to_integer(port)}
  end

  defp maybe_handle_standalone_command do
    case Wardwright.CLI.run(argv()) do
      {:halt, status} -> System.halt(status)
      :start -> :ok
    end
  end

  defp argv do
    if System.get_env("__BURRITO") do
      :init.get_plain_arguments() |> Enum.map(&to_string/1)
    else
      System.argv()
    end
  end
end
