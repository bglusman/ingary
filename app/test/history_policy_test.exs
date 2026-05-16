defmodule Wardwright.HistoryPolicyTest do
  use Wardwright.RouterCase

  test "history threshold policy reads only configured cache scope" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("governance", [
        %{
          "id" => "repeat-tool",
          "kind" => "history_threshold",
          "action" => "escalate",
          "cache_kind" => "tool_call",
          "cache_key" => "shell:ls",
          "cache_scope" => "session_id",
          "threshold" => 2,
          "severity" => "warning"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-a"}
           }).status == 201

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-b"}
           }).status == 201

    miss =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    assert miss.status == 200
    assert get_in(Jason.decode!(miss.resp_body), ["receipt", "final", "alert_count"]) == 0

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-a"}
           }).status == 201

    hit =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    body = Jason.decode!(hit.resp_body)
    assert get_in(body, ["receipt", "final", "alert_count"]) == 1

    assert get_in(body, ["receipt", "decision", "policy_actions", Access.at(0), "history_count"]) ==
             2
  end

  test "history threshold can count normalized tool context from current session requests" do
    cache_key = "mcp.github:create_pull_request:planning"

    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("governance", [
        %{
          "id" => "repeat-pr-tool",
          "kind" => "history_threshold",
          "action" => "escalate",
          "cache_kind" => "tool_call",
          "cache_key" => cache_key,
          "cache_scope" => "session_id",
          "threshold" => 1,
          "severity" => "warning"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{
          request: %{
            model: "unit-model",
            messages: [%{role: "user", content: "open a pull request"}],
            metadata: %{
              tool_context: %{
                phase: "planning",
                primary_tool: %{
                  namespace: "mcp.github",
                  name: "create_pull_request",
                  risk_class: "write"
                },
                tool_call_id: "call_1"
              }
            }
          }
        },
        [{"x-wardwright-session-id", "session-tools"}]
      )

    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["receipt", "final", "alert_count"]) == 1

    assert get_in(body, ["receipt", "decision", "policy_actions", Access.at(0), "history_count"]) ==
             1

    assert [%{"kind" => "tool_call", "key" => ^cache_key, "value" => value}] =
             Wardwright.PolicyCache.recent(
               %{"kind" => "tool_call", "scope" => %{"session_id" => "session-tools"}},
               10
             )

    assert value["tool_call_id"] == "call_1"
    assert get_in(value, ["primary_tool", "namespace"]) == "mcp.github"
  end

  test "history threshold uses safe defaults for blank operator-facing fields" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("governance", [
        %{
          "id" => "repeat-tool",
          "kind" => "history_threshold",
          "action" => "annotate",
          "cache_kind" => "tool_call",
          "cache_key" => "shell:ls",
          "cache_scope" => "session_id",
          "threshold" => 0,
          "message" => "",
          "severity" => ""
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-a"}
           }).status == 201

    conn =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    action =
      get_in(Jason.decode!(conn.resp_body), [
        "receipt",
        "decision",
        "policy_actions",
        Access.at(0)
      ])

    assert action["message"] == "policy cache threshold matched"
    assert action["severity"] == "info"
    assert action["threshold"] == 1
    assert action["history_count"] == 1
  end

  test "history regex threshold uses automatically recorded request text inside session scope" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("governance", [
        %{
          "id" => "dangerous-shell-history",
          "kind" => "history_regex_threshold",
          "action" => "alert_async",
          "cache_kind" => "request_text",
          "cache_key" => "chat_completion",
          "cache_scope" => "session_id",
          "pattern" => "rm\\s+-rf",
          "threshold" => 1,
          "severity" => "critical"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    miss =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    assert get_in(Jason.decode!(miss.resp_body), ["receipt", "final", "alert_count"]) == 0

    hit =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{
          request: %{
            model: "unit-model",
            messages: [%{role: "user", content: "please run rm -rf /tmp/demo"}]
          }
        },
        [{"x-wardwright-session-id", "session-a"}]
      )

    receipt = Jason.decode!(hit.resp_body)["receipt"]
    assert get_in(receipt, ["final", "alert_count"]) == 1
    assert [%{"outcome" => "queued"}] = get_in(receipt, ["final", "alert_delivery"])

    isolated =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-b"}]
      )

    assert get_in(Jason.decode!(isolated.resp_body), ["receipt", "final", "alert_count"]) == 0
  end
end
