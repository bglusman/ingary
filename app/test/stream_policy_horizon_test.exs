defmodule Wardwright.StreamPolicyHorizonTest do
  use Wardwright.RouterCase

  test "stream policy bounded horizon releases remaining held bytes on completion" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["alpha ", "beta ", "gamma"],
        [
          %{
            "id" => "never-matches",
            "contains" => "OldClient(",
            "action" => "block",
            "horizon_bytes" => byte_size("OldClient(")
          }
        ]
      )

    assert result.status == "completed"
    assert Enum.join(result.chunks) == "alpha beta gamma"
    assert result.generated_bytes == byte_size("alpha beta gamma")
    assert result.released_bytes == result.generated_bytes
    assert result.held_bytes == 0
    assert result.stream_buffer == ""
    assert result.max_held_bytes <= byte_size("OldClient(")
  end

  test "stream policy latency budget fails closed when held bytes age past budget" do
    state =
      Wardwright.Policy.Stream.start(
        [
          %{
            "id" => "latency-budget",
            "contains" => "OldClient(",
            "action" => "block",
            "horizon_bytes" => byte_size("OldClient("),
            "max_hold_ms" => 5
          }
        ],
        now_ms: 100
      )

    {:cont, state, []} = Wardwright.Policy.Stream.consume(state, "held", now_ms: 100)
    {:halt, state, []} = Wardwright.Policy.Stream.consume(state, " later", now_ms: 106)

    assert state.status == "stream_policy_latency_exceeded"
    assert state.action == "fail_closed"
    assert state.released_to_consumer == false
    assert state.released_bytes == 0
    assert state.max_hold_ms == 5
    assert state.max_observed_hold_ms == 6
    assert state.held_bytes == byte_size("held later")
    held_bytes = byte_size("held")

    assert [
             %{
               "type" => "stream_policy.latency_exceeded",
               "action" => "fail_closed",
               "chunk_index" => 1,
               "max_hold_ms" => 5,
               "observed_hold_ms" => 6,
               "held_bytes" => ^held_bytes
             }
           ] = state.events
  end

  test "stream policy bounded horizon never splits utf8 codepoints" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["ééé", "abc"],
        [
          %{
            "id" => "unicode-near-miss",
            "contains" => "missing",
            "action" => "block",
            "horizon_bytes" => 3
          }
        ]
      )

    assert result.status == "completed"
    assert Enum.join(result.chunks) == "éééabc"
    assert Enum.all?(result.chunks, &String.valid?/1)
    assert result.released_bytes == byte_size("éééabc")
  end

  test "stream policy bounded horizon rewrites without duplicating held prefixes" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["abc ", "OldClient(", " done"],
        [
          %{
            "id" => "bounded-rewrite",
            "contains" => "OldClient(",
            "action" => "rewrite_chunk",
            "replacement" => "NewClient(",
            "horizon_bytes" => byte_size("OldClient(")
          }
        ]
      )

    assert result.status == "completed"
    assert Enum.join(result.chunks) == "abc NewClient( done"
    refute Enum.join(result.chunks) =~ "OldClient("
    assert result.rewritten_bytes > 0
  end

  test "stream policy bounded horizon never flushes dropped chunks at completion" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["keep ", "DROP", " done"],
        [
          %{
            "id" => "bounded-drop",
            "contains" => "DROP",
            "action" => "drop_chunk",
            "horizon_bytes" => 5
          }
        ]
      )

    assert result.status == "completed"
    assert Enum.join(result.chunks) == "keep  done"
    refute Enum.join(result.chunks) =~ "DROP"
    assert result.generated_bytes == byte_size("keep DROP done")
    assert result.released_bytes == byte_size("keep  done")
  end

  test "stream policy incremental arbiter emits safe prefixes before a later block" do
    state =
      Wardwright.Policy.Stream.start([
        %{
          "id" => "incremental-block",
          "contains" => "OldClient(",
          "action" => "block",
          "horizon_bytes" => byte_size("OldClient(")
        }
      ])

    {:cont, state, first_release} =
      Wardwright.Policy.Stream.consume(state, "safe prefix that can release ")

    {:cont, state, second_release} = Wardwright.Policy.Stream.consume(state, "Old")
    {:halt, state, terminal_release} = Wardwright.Policy.Stream.consume(state, "Client(arg)")

    released = Enum.join(first_release ++ second_release ++ terminal_release)

    assert released != ""
    refute released =~ "Old"
    refute released =~ "Client("
    assert terminal_release == []
    assert state.status == "stream_policy_blocked"
    assert state.released_bytes == byte_size(released)
    assert state.held_bytes > byte_size("OldClient(")

    assert {:halt, ^state, []} = Wardwright.Policy.Stream.consume(state, " ignored")
  end

  test "stream policy incremental arbiter flushes held suffix on finish" do
    state =
      Wardwright.Policy.Stream.start([
        %{
          "id" => "incremental-finish",
          "contains" => "OldClient(",
          "action" => "block",
          "horizon_bytes" => byte_size("OldClient(")
        }
      ])

    {:cont, state, first_release} = Wardwright.Policy.Stream.consume(state, "alpha ")
    {:cont, state, second_release} = Wardwright.Policy.Stream.consume(state, "beta ")
    {:cont, state, third_release} = Wardwright.Policy.Stream.consume(state, "gamma")
    {state, final_release} = Wardwright.Policy.Stream.finish(state)

    assert state.status == "completed"

    assert Enum.join(first_release ++ second_release ++ third_release ++ final_release) ==
             "alpha beta gamma"

    assert state.stream_buffer == ""
    assert state.held_bytes == 0
  end

  test "stream policy incremental arbiter handles bounded rewrite and drop actions" do
    rewrite_state =
      Wardwright.Policy.Stream.start([
        %{
          "id" => "incremental-rewrite",
          "contains" => "OldClient(",
          "action" => "rewrite_chunk",
          "replacement" => "NewClient(",
          "horizon_bytes" => byte_size("OldClient(")
        }
      ])

    {:cont, rewrite_state, first_release} =
      Wardwright.Policy.Stream.consume(rewrite_state, "abc ")

    {:cont, rewrite_state, second_release} =
      Wardwright.Policy.Stream.consume(rewrite_state, "OldClient(")

    {rewrite_state, final_release} = Wardwright.Policy.Stream.finish(rewrite_state)
    rewritten = Enum.join(first_release ++ second_release ++ final_release)

    assert rewrite_state.status == "completed"
    assert rewritten == "abc NewClient("
    refute rewritten =~ "OldClient("

    drop_state =
      Wardwright.Policy.Stream.start([
        %{
          "id" => "incremental-drop",
          "contains" => "DROP",
          "action" => "drop_chunk",
          "horizon_bytes" => 5
        }
      ])

    {:cont, drop_state, first_release} = Wardwright.Policy.Stream.consume(drop_state, "keep ")
    {:cont, drop_state, second_release} = Wardwright.Policy.Stream.consume(drop_state, "DROP")
    {:cont, drop_state, third_release} = Wardwright.Policy.Stream.consume(drop_state, " done")
    {drop_state, final_release} = Wardwright.Policy.Stream.finish(drop_state)
    dropped = Enum.join(first_release ++ second_release ++ third_release ++ final_release)

    assert drop_state.status == "completed"
    assert dropped == "keep  done"
    refute dropped =~ "DROP"
  end
end
