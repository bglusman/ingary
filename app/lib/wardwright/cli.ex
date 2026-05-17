defmodule Wardwright.CLI do
  @moduledoc false

  def run(argv, write_fun \\ &IO.puts/1) do
    case argv do
      ["--version" | _] ->
        write_fun.(version())
        {:halt, 0}

      ["version" | _] ->
        write_fun.(version())
        {:halt, 0}

      ["--help" | _] ->
        write_fun.(help())
        {:halt, 0}

      ["help" | _] ->
        write_fun.(help())
        {:halt, 0}

      ["tools", "--json" | _] ->
        WardwrightWeb.PolicyAuthoringTools.list()
        |> Jason.encode!()
        |> write_fun.()

        {:halt, 0}

      ["tools" | _] ->
        write_fun.(tools_help())
        {:halt, 0}

      [] ->
        :start

      _unknown ->
        :start
    end
  end

  defp help do
    """
    wardwright #{version()}

    Usage:
      wardwright                Start the Wardwright HTTP service
      wardwright tools          Print policy-authoring MCP/API help for agents
      wardwright tools --json   Print machine-readable authoring tool metadata
      wardwright --version      Print the packaged app version

    Runtime environment:
      WARDWRIGHT_BIND             Host and port, default 127.0.0.1:8787
      WARDWRIGHT_SECRET_KEY_BASE  Stable Phoenix signing secret for services
      WARDWRIGHT_ADMIN_TOKEN      Optional token for protected local APIs
    """
  end

  defp tools_help do
    tools = WardwrightWeb.PolicyAuthoringTools.cli_descriptions() |> Enum.join("\n")

    """
    Wardwright policy-authoring tools

    Start Wardwright, then point MCP-capable agents at:
      http://127.0.0.1:8787/mcp

    Local HTTP tools are protected by loopback access or WARDWRIGHT_ADMIN_TOKEN.
    When Wardwright is bound to another port, replace 8787 with WARDWRIGHT_BIND.

    Tools:
    #{tools}
    """
  end

  defp version do
    :wardwright
    |> Application.spec(:vsn)
    |> to_string()
  end
end
