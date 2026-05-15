defmodule ElixirIngary.PolicySandbox.DuneTest do
  use ExUnit.Case, async: true

  alias ElixirIngary.PolicySandbox.Dune, as: DuneSandbox

  test "evaluates a deterministic policy-shaped result" do
    result =
      DuneSandbox.eval_string("""
      private_risk = true
      cloud_approved = false

      if private_risk and not cloud_approved do
        %{"action" => "restrict_routes", "allowed_targets" => ["local"]}
      else
        %{"action" => "allow_routes", "allowed_targets" => ["local", "cloud"]}
      end
      """)

    assert %{
             "status" => "ok",
             "value" => %{"action" => "restrict_routes", "allowed_targets" => ["local"]},
             "stdio" => ""
           } = result
  end

  test "parses without atom leaks and exposes a reviewable AST string" do
    result = DuneSandbox.parse_string("rule_name = :private_route_gate")

    assert result["status"] == "ok"
    assert result["inspected"] =~ "private_route_gate"
    assert inspect(result["value"]) =~ "__Dune_atom_"
  end

  test "forbidden host APIs fail closed with restricted errors" do
    for source <- [
          "File.cwd!()",
          "System.get_env()",
          "spawn(fn -> :ok end)",
          "send(self(), :leak)"
        ] do
      assert %{"status" => "error", "reason" => reason, "message" => message} =
               DuneSandbox.eval_string(source)

      assert reason in ["restricted", "module_restricted"]
      assert message =~ "restricted"
    end
  end

  test "reduction limit stops CPU-heavy policy work" do
    result =
      DuneSandbox.eval_string(
        """
        Enum.reduce(1..100_000, 0, fn i, acc ->
          Integer.gcd(i, acc + i)
        end)
        """,
        max_heap_size: 1_000_000,
        max_reductions: 2_000,
        timeout: 1_000
      )

    assert %{"status" => "error", "reason" => "reductions"} = result
  end

  test "memory limit stops large allocations" do
    result =
      DuneSandbox.eval_string(
        "List.duplicate(\"policy-event\", 100_000)",
        max_heap_size: 4_000,
        timeout: 1_000
      )

    assert %{"status" => "error", "reason" => "memory"} = result
  end

  test "wall clock timeout stops allowed slow code" do
    result =
      DuneSandbox.eval_string(
        """
        Enum.reduce(1..1_000_000, 0, fn i, acc ->
          Integer.gcd(i, acc + i)
        end)
        """,
        max_reductions: 10_000_000,
        timeout: 1
      )

    assert %{"status" => "error", "reason" => reason} = result
    assert reason in ["timeout", "reductions"]
  end
end
