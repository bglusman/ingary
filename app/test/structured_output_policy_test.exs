defmodule Wardwright.StructuredOutputPolicyTest do
  use Wardwright.RouterCase

  test "provider runtime enforces target timeouts and publishes attempt visibility" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{
          "model" => "slow/model",
          "context_window" => 256,
          "provider_kind" => "canned_sequence",
          "canned_outputs" => ["late answer"],
          "canned_delay_ms" => 25,
          "provider_timeout_ms" => 1
        }
      ])
      |> Map.put("governance", [])

    assert :ok = Wardwright.Runtime.Events.subscribe(Wardwright.Runtime.Events.topic(:models))
    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "hello"}]
      })

    assert conn.status == 502
    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "provider_error"
    assert get_in(body, ["wardwright", "provider_error"]) =~ "provider timed out after 1ms"

    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()
    assert get_in(receipt, ["attempts", Access.at(0), "called_provider"]) == true
    assert get_in(receipt, ["attempts", Access.at(0), "mock"]) == false

    assert_receive {:wardwright_runtime_event, "runtime:models",
                    %{
                      "type" => "provider.attempt.started",
                      "provider_id" => "slow",
                      "model" => "slow/model",
                      "timeout_ms" => 1
                    }}

    assert_receive {:wardwright_runtime_event, "runtime:models",
                    %{
                      "type" => "provider.attempt.finished",
                      "provider_id" => "slow",
                      "model" => "slow/model",
                      "status" => "provider_error"
                    }}
  end

  test "structured output guard retries canned provider outputs and records guard receipts" do
    config =
      structured_policy_config(
        [
          "{not json",
          ~s({"answer":"missing confidence"}),
          ~s({"answer":"valid and confident","confidence":0.91})
        ],
        3
      )

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "return structured json"}]
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    structured = get_in(body, ["wardwright", "structured_output"])
    assert structured["final_status"] == "completed_after_guard"
    assert structured["selected_schema"] == "answer_v1"
    assert structured["attempt_count"] == 3

    assert Enum.map(structured["guard_events"], & &1["guard_type"]) == [
             "json_syntax",
             "schema_validation"
           ]

    assert get_in(body, ["choices", Access.at(0), "message", "content"]) ==
             ~s({"answer":"valid and confident","confidence":0.91})
  end

  test "structured output guard fails closed when per-rule budget is exhausted" do
    config =
      structured_policy_config([
        ~s({"answer":"too uncertain one","confidence":0.1}),
        ~s({"answer":"too uncertain two","confidence":0.2}),
        ~s({"answer":"would have succeeded too late","confidence":0.95})
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "return structured json"}]
      })

    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)

    structured = get_in(body, ["wardwright", "structured_output"])
    assert structured["final_status"] == "exhausted_rule_budget"
    assert structured["exhausted_rule_id"] == "minimum-confidence"

    assert Enum.map(structured["guard_events"], & &1["rule_id"]) == [
             "minimum-confidence",
             "minimum-confidence"
           ]
  end

  test "structured semantic rules reject matched JSON pointer strings" do
    config =
      structured_policy_config([~s({"answer":"draft answer","confidence":0.95})], 3)
      |> get_in(["structured_output"])
      |> update_in(["semantic_rules"], fn rules ->
        rules ++
          [
            %{
              "id" => "answer-not-draft",
              "kind" => "json_path_string_not_contains",
              "path" => "/answer",
              "pattern" => "draft"
            }
          ]
      end)

    assert {:error, "semantic_validation", "answer-not-draft"} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":"draft answer","confidence":0.95}),
               config
             )

    assert {:ok, "answer_v1", %{"answer" => "final answer", "confidence" => 0.95}} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":"final answer","confidence":0.95}),
               config
             )
  end

  test "structured schema and semantic validation fail closed for boundary violations" do
    config = structured_policy_config([~s({"answer":"unused","confidence":0.95})], 3)

    for invalid_output <- [
          ~s({"answer":"extra field","confidence":0.95,"debug":true}),
          ~s({"answer":"too high","confidence":1.01}),
          ~s({"answer":"","confidence":0.95}),
          ~s({"answer":"bad citation","confidence":0.95,"citations":[123]})
        ] do
      assert {:error, "schema_validation", "structured-json"} =
               Wardwright.Policy.StructuredOutput.validate_output(
                 invalid_output,
                 config["structured_output"]
               )
    end

    invalid_path_config =
      config
      |> get_in(["structured_output"])
      |> put_in(["semantic_rules"], [
        %{
          "id" => "confidence-pointer-required",
          "kind" => "json_path_number",
          "path" => "confidence",
          "gte" => 0.7
        }
      ])

    assert {:error, "semantic_validation", "confidence-pointer-required"} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":"valid","confidence":0.95}),
               invalid_path_config
             )
  end

  test "structured semantic rules traverse nested JSON pointer paths" do
    config =
      structured_policy_config([~s({"answer":"unused","confidence":0.95})], 3)
      |> get_in(["structured_output"])
      |> put_in(["schemas"], %{
        "nested_answer_v1" => %{
          "type" => "object",
          "required" => ["answer"],
          "properties" => %{},
          "additionalProperties" => true
        }
      })
      |> put_in(["semantic_rules"], [
        %{
          "id" => "nested-minimum-confidence",
          "kind" => "json_path_number",
          "path" => "/answer/confidence",
          "gte" => 0.7
        }
      ])

    assert {:error, "semantic_validation", "nested-minimum-confidence"} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":{"text":"too uncertain","confidence":0.2}}),
               config
             )

    assert {:ok, "nested_answer_v1", _parsed} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":{"text":"confident","confidence":0.91}}),
               config
             )
  end

  test "structured guard honors integer attempt budgets exactly" do
    config =
      structured_policy_config(["{not json"], 5)
      |> get_in(["structured_output"])
      |> put_in(["guard_loop", "max_attempts"], 2)

    provider = fn _attempt_index ->
      %{
        content: "{not json",
        status: "completed",
        latency_ms: 0,
        error: nil,
        called_provider: false,
        mock: true,
        structured_output: nil
      }
    end

    result = Wardwright.Policy.StructuredOutput.run(config, provider)
    assert result.status == "exhausted_guard_budget"
    assert get_in(result.structured_output, ["attempt_count"]) == 2
    assert length(get_in(result.structured_output, ["guard_events"])) == 2
  end
end
