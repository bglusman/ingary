defmodule Wardwright.CLITest do
  use ExUnit.Case, async: true

  test "help advertises the service and authoring tools command" do
    collector = collector()

    assert {:halt, 0} = Wardwright.CLI.run(["--help"], collector)

    output = collected(collector)
    assert output =~ "Start the Wardwright HTTP service"
    assert output =~ "wardwright tools"
    assert output =~ "WARDWRIGHT_BIND"
  end

  test "tools command prints agent-usable MCP and API guidance" do
    collector = collector()

    assert {:halt, 0} = Wardwright.CLI.run(["tools"], collector)

    output = collected(collector)
    assert output =~ "http://127.0.0.1:8787/mcp"
    assert output =~ "WARDWRIGHT_ADMIN_TOKEN"
    assert output =~ "explain_projection"
    assert output =~ "GET /v1/policy-authoring/projections/{pattern_id}"
    assert output =~ "validate_policy_artifact"
  end

  test "tools JSON is generated from the authoring tool registry" do
    collector = collector()

    assert {:halt, 0} = Wardwright.CLI.run(["tools", "--json"], collector)

    names =
      collector
      |> collected()
      |> Jason.decode!()
      |> Enum.map(& &1["name"])

    assert "simulate_policy" in names
    assert "record_scenario" in names
    assert "validate_policy_artifact" in names
  end

  defp collector do
    owner = self()

    fn line ->
      send(owner, {:cli_output, line})
    end
  end

  defp collected(_collector) do
    collect_messages([])
  end

  defp collect_messages(lines) do
    receive do
      {:cli_output, line} -> collect_messages([line | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
