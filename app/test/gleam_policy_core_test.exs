defmodule Wardwright.GleamPolicyCoreTest do
  use ExUnit.Case, async: true

  alias Wardwright.Policy.CoreRuntime

  test "structured core classifies successful guard-loop outcomes" do
    assert Wardwright.Policy.StructuredCore.success_status(0) == "completed"
    assert Wardwright.Policy.StructuredCore.success_status(2) == "completed_after_guard"

    assert Wardwright.Policy.StructuredCore.guard_rule_id_for_string(
             "semantic_validation",
             "structured-json",
             "minimum-confidence"
           ) == "minimum-confidence"
  end

  test "structured core classifies guard budget exhaustion before another retry" do
    assert Wardwright.Policy.StructuredCore.loop_outcome_status(
             "minimum-confidence",
             2,
             2,
             2,
             4
           ) == "exhausted_rule_budget"

    assert Wardwright.Policy.StructuredCore.loop_outcome_status(
             "structured-json",
             1,
             2,
             4,
             4
           ) == "exhausted_guard_budget"

    assert Wardwright.Policy.StructuredCore.loop_outcome_status(
             "structured-json",
             1,
             2,
             3,
             4
           ) == "continue"
  end

  test "history core classifies threshold decisions over the recent window" do
    decision =
      Wardwright.Policy.HistoryCore.count_decision([true, false, true, true],
        threshold: 2,
        recent_limit: 3,
        working_set_size: 4,
        scope: "session_id"
      )

    assert {:triggered, "session_id", 2, 2, 3, 4} = decision

    decision =
      Wardwright.Policy.HistoryCore.count_decision([true, true, true, true],
        threshold: 3,
        recent_limit: 2,
        working_set_size: 4,
        scope: "session_id"
      )

    assert {:not_triggered, "session_id", 2, 3, 2, 4} = decision

    assert Wardwright.Policy.HistoryCore.triggered_count?(3, 3)
    refute Wardwright.Policy.HistoryCore.triggered_count?(2, 3)
  end

  test "alert core classifies queue capacity, duplicate, and terminal states" do
    config = %{"capacity" => 1, "on_full" => "dead_letter"}
    alert = %{"idempotency_key" => "key-1", "rule_id" => "alert-rule", "session_id" => "s1"}

    assert %{
             key: "key-1",
             outcome: "queued",
             queue_depth: 1,
             queue_capacity: 1
           } = Wardwright.Policy.AlertCore.decide_enqueue(config, 0, false, alert)

    assert %{outcome: "duplicate_suppressed"} =
             Wardwright.Policy.AlertCore.decide_enqueue(config, 1, true, alert)

    assert %{outcome: "dead_lettered"} =
             Wardwright.Policy.AlertCore.decide_enqueue(config, 1, false, alert)

    refute Wardwright.Policy.AlertCore.terminal?(:enqueued)
    assert Wardwright.Policy.AlertCore.terminal?(:dead_lettered)
  end

  test "Elixir and Gleam policy cores remain equivalent for representative decisions" do
    assert in_core(:compare, fn ->
             [
               Wardwright.Policy.StructuredCore.success_status(1),
               Wardwright.Policy.StructuredCore.loop_outcome_status(
                 "structured-json",
                 1,
                 3,
                 1,
                 2
               ),
               Wardwright.Policy.HistoryCore.count_decision([true, false, true],
                 threshold: 2,
                 recent_limit: 3,
                 working_set_size: 3,
                 scope: "session_id"
               ),
               Wardwright.Policy.AlertCore.decide_enqueue(
                 %{"capacity" => 1, "on_full" => "fail_closed"},
                 1,
                 false,
                 %{"idempotency_key" => "key-1", "rule_id" => "alert-rule"}
               )
             ]
           end) ==
             in_core(:elixir, fn ->
               [
                 Wardwright.Policy.StructuredCore.success_status(1),
                 Wardwright.Policy.StructuredCore.loop_outcome_status(
                   "structured-json",
                   1,
                   3,
                   1,
                   2
                 ),
                 Wardwright.Policy.HistoryCore.count_decision([true, false, true],
                   threshold: 2,
                   recent_limit: 3,
                   working_set_size: 3,
                   scope: "session_id"
                 ),
                 Wardwright.Policy.AlertCore.decide_enqueue(
                   %{"capacity" => 1, "on_full" => "fail_closed"},
                   1,
                   false,
                   %{"idempotency_key" => "key-1", "rule_id" => "alert-rule"}
                 )
               ]
             end)
  end

  defp in_core(core, fun), do: CoreRuntime.with_core(core, fun)
end
