defmodule Wardwright.ToolContextPolicyTest do
  use Wardwright.RouterCase

  test "tool selector applies a different route policy for the same public model" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "local/read", "context_window" => 512},
        %{"model" => "managed/write", "context_window" => 512}
      ])
      |> Map.put("governance", [
        %{
          "id" => "github-write-tools",
          "kind" => "tool_selector",
          "action" => "switch_model",
          "target_model" => "managed/write",
          "attach_policy_bundle" => "github_write_planning_v1",
          "tool" => %{
            "namespace" => "mcp.github",
            "name" => "create_pull_request",
            "phase" => "planning",
            "risk_class" => "write"
          }
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    write_conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          metadata: %{
            tool_context: %{
              phase: "planning",
              primary_tool: %{
                namespace: "mcp.github",
                name: "create_pull_request",
                risk_class: "write"
              }
            }
          },
          messages: [%{role: "user", content: "open a review PR"}]
        }
      })

    assert write_conn.status == 200
    write_receipt = write_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(write_receipt, ["decision", "selected_model"]) == "managed/write"

    assert get_in(write_receipt, ["decision", "policy_route_constraints"]) == %{
             "forced_model" => "managed/write"
           }

    assert [
             %{
               "id" => "github-write-tools",
               "matched" => true,
               "attached_policy_bundle" => "github_write_planning_v1"
             }
           ] = get_in(write_receipt, ["decision", "tool_policy_selectors"])

    assert get_in(write_receipt, ["decision", "tool_context", "primary_tool", "name"]) ==
             "create_pull_request"

    read_conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          metadata: %{
            tool_context: %{
              phase: "planning",
              primary_tool: %{
                namespace: "browser",
                name: "read_page",
                risk_class: "read_only"
              }
            }
          },
          messages: [%{role: "user", content: "summarize this page"}]
        }
      })

    read_receipt = read_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(read_receipt, ["decision", "selected_model"]) == "local/read"

    assert [%{"id" => "github-write-tools", "matched" => false}] =
             get_in(read_receipt, ["decision", "tool_policy_selectors"])
  end

  test "OpenAI tool_choice is normalized and can drive route constraints" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "local/qwen", "context_window" => 512},
        %{"model" => "managed/kimi", "context_window" => 512}
      ])
      |> Map.put("governance", [
        %{
          "id" => "ticket-writes-managed",
          "kind" => "tool_selector",
          "action" => "restrict_routes",
          "allowed_targets" => ["managed"],
          "tool" => %{"namespace" => "openai.function", "name" => "create_ticket"}
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          tools: [
            %{
              type: "function",
              function: %{
                name: "create_ticket",
                parameters: %{type: "object", properties: %{title: %{type: "string"}}}
              }
            }
          ],
          tool_choice: %{type: "function", function: %{name: "create_ticket"}},
          messages: [%{role: "user", content: "file this incident"}]
        }
      })

    receipt = conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(receipt, ["decision", "selected_model"]) == "managed/kimi"

    assert get_in(receipt, ["decision", "policy_route_constraints"]) == %{
             "allowed_targets" => ["managed"]
           }

    assert get_in(receipt, ["decision", "tool_context", "primary_tool", "source"]) ==
             "tool_choice"

    assert get_in(receipt, [
             "decision",
             "tool_context",
             "available_tools",
             Access.at(0),
             "schema_hash"
           ]) =~ "sha256:"

    receipt_id = receipt["receipt_id"]

    list_conn =
      call(:get, "/v1/receipts?tool_namespace=openai.function&tool_name=create_ticket")

    assert %{"data" => [%{"receipt_id" => ^receipt_id, "tool_name" => "create_ticket"}]} =
             Jason.decode!(list_conn.resp_body)
  end

  test "tool loop threshold uses bounded session history without raw tool payloads" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("targets", [
        %{"model" => "local/read", "context_window" => 512},
        %{"model" => "managed/write", "context_window" => 512}
      ])
      |> Map.put("governance", [
        %{
          "id" => "repeat-github-write",
          "kind" => "tool_loop_threshold",
          "action" => "switch_model",
          "target_model" => "managed/write",
          "threshold" => 2,
          "cache_scope" => "session_id",
          "tool" => %{"namespace" => "mcp.github", "name" => "create_pull_request"}
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    request = %{
      model: "unit-model",
      metadata: %{
        session_id: "session-tool-loop",
        tool_context: %{
          phase: "planning",
          primary_tool: %{
            namespace: "mcp.github",
            name: "create_pull_request",
            risk_class: "write"
          }
        }
      },
      messages: [%{role: "user", content: "open the same PR"}]
    }

    first = call(:post, "/v1/synthetic/simulate", %{request: request})
    first_receipt = first.resp_body |> Jason.decode!() |> get_in(["receipt"])
    assert get_in(first_receipt, ["decision", "selected_model"]) == "local/read"
    refute get_in(first_receipt, ["final", "tool_policy"])

    second = call(:post, "/v1/synthetic/simulate", %{request: request})
    second_receipt = second.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(second_receipt, ["decision", "selected_model"]) == "managed/write"

    assert get_in(second_receipt, ["final", "tool_policy"]) == %{
             "status" => "rerouted",
             "rule_id" => "repeat-github-write",
             "state_scope" => "session",
             "counter_key_hash" =>
               "sha256:7fb7926b3c1195c75763a9c0f9d04b8a182690da45331f2766ed64f232322e75",
             "threshold" => 2,
             "observed_count" => 2
           }

    assert [
             %{
               "kind" => "tool_context",
               "key" => "mcp.github:create_pull_request:planning",
               "value" => %{
                 "primary_tool" => %{
                   "namespace" => "mcp.github",
                   "name" => "create_pull_request"
                 }
               }
             }
             | _
           ] = Wardwright.PolicyCache.recent(%{"kind" => "tool_context"}, 2)
  end

  test "assistant tool calls produce redacted hashes instead of raw arguments" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "local/read", "context_window" => 512},
        %{"model" => "managed/write", "context_window" => 512}
      ])
      |> Map.put("governance", [
        %{
          "id" => "shell-write",
          "kind" => "tool_selector",
          "action" => "switch_model",
          "target_model" => "managed/write",
          "tool" => %{"namespace" => "openai.function", "name" => "run_shell"}
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [
            %{role: "user", content: "prepare the command"},
            %{
              role: "assistant",
              content: nil,
              tool_calls: [
                %{
                  id: "call_secret",
                  type: "function",
                  function: %{
                    name: "run_shell",
                    arguments: ~s({"command":"echo secret-token-123"})
                  }
                }
              ]
            }
          ]
        }
      })

    receipt = conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(receipt, ["decision", "selected_model"]) == "managed/write"
    assert get_in(receipt, ["decision", "tool_context", "argument_hash"]) =~ "sha256:"
    refute inspect(receipt) =~ "secret-token-123"

    [event | _] = Wardwright.PolicyCache.recent(%{"kind" => "tool_context"}, 1)
    assert get_in(event, ["value", "argument_hash"]) =~ "sha256:"
    refute inspect(event) =~ "secret-token-123"
  end
end
