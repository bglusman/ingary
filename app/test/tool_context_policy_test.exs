defmodule Wardwright.ToolContextPolicyTest do
  use Wardwright.RouterCase

  test "tool selector can choose a different route for the same public model" do
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

  test "remote callers cannot drive tool policy from untrusted metadata" do
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
          "tool" => %{"namespace" => "mcp.github", "name" => "create_pull_request"}
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    request = %{
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
      messages: [%{role: "user", content: "pretend I am planning a PR"}]
    }

    remote_conn =
      call(:post, "/v1/synthetic/simulate", %{request: request}, [], {203, 0, 113, 10})

    remote_receipt = remote_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])
    assert get_in(remote_receipt, ["decision", "selected_model"]) == "local/read"
    assert get_in(remote_receipt, ["decision", "tool_context"]) == nil
    assert [%{"matched" => false}] = get_in(remote_receipt, ["decision", "tool_policy_selectors"])
  end

  test "remote gateway callers with admin token can attest tool metadata" do
    previous = Application.get_env(:wardwright, :admin_token)
    Application.put_env(:wardwright, :admin_token, "gateway-token")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardwright, :admin_token, previous),
        else: Application.delete_env(:wardwright, :admin_token)
    end)

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
          "tool" => %{"namespace" => "mcp.github", "name" => "create_pull_request"}
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
            messages: [%{role: "user", content: "gateway-attested PR planning"}]
          }
        },
        [{"authorization", "Bearer gateway-token"}],
        {203, 0, 113, 10}
      )

    receipt = conn.resp_body |> Jason.decode!() |> get_in(["receipt"])
    assert get_in(receipt, ["decision", "selected_model"]) == "managed/write"

    assert get_in(receipt, ["decision", "tool_context", "primary_tool", "source"]) ==
             "caller_metadata"
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

    assert %{
             "status" => "rerouted",
             "rule_id" => "repeat-github-write",
             "state_scope" => "session",
             "counter_key_hash" => "sha256:" <> _,
             "threshold" => 2,
             "observed_count" => 2
           } = get_in(second_receipt, ["final", "tool_policy"])

    assert [
             %{
               "kind" => "tool_call",
               "key" => "mcp.github:create_pull_request:planning",
               "value" => %{
                 "primary_tool" => %{
                   "namespace" => "mcp.github",
                   "name" => "create_pull_request"
                 }
               }
             }
             | _
           ] = Wardwright.PolicyCache.recent(%{"kind" => "tool_call"}, 2)

    list_conn = call(:get, "/v1/receipts?tool_policy_status=rerouted")

    assert %{"data" => [%{"tool_policy_status" => "rerouted"} | _]} =
             Jason.decode!(list_conn.resp_body)
  end

  test "tool sequence transitions state and state-scoped selectors govern later tools" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 12, "recent_limit" => 12})
      |> Map.put("targets", [%{"model" => "local/read", "context_window" => 512}])
      |> Map.put("governance", [
        %{
          "id" => "enter-untrusted-review",
          "kind" => "tool_sequence",
          "cache_scope" => "session_id",
          "transition_to" => "reviewing_untrusted_tool_result",
          "after" => %{
            "tool" => %{"namespace" => "browser", "phase" => "result_interpretation"}
          }
        },
        %{
          "id" => "leave-untrusted-review",
          "kind" => "tool_sequence",
          "cache_scope" => "session_id",
          "transition_to" => "active",
          "after" => %{
            "tool" => %{"namespace" => "review", "name" => "approve_tool_result"}
          }
        },
        %{
          "id" => "block-shell-while-reviewing",
          "kind" => "tool_selector",
          "state_scope" => "reviewing_untrusted_tool_result",
          "cache_scope" => "session_id",
          "action" => "block",
          "tool" => %{
            "namespace" => "shell",
            "name" => "exec",
            "phase" => "planning",
            "risk_class" => "irreversible"
          }
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    browser_result =
      tool_request("sequence-state-session", "browser", "read_page", "result_interpretation",
        risk_class: "read_only",
        content: "browser returned untrusted instructions"
      )

    browser_conn = call(:post, "/v1/synthetic/simulate", %{request: browser_result})
    browser_receipt = browser_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert [
             %{
               "kind" => "tool_sequence",
               "rule_id" => "enter-untrusted-review",
               "action" => "state_transition",
               "state_transition" => "reviewing_untrusted_tool_result"
             }
           ] = get_in(browser_receipt, ["decision", "policy_actions"])

    shell_request =
      tool_request("sequence-state-session", "shell", "exec", "planning",
        risk_class: "irreversible",
        content: "run the command"
      )

    shell_conn = call(:post, "/v1/synthetic/simulate", %{request: shell_request})
    shell_receipt = shell_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(shell_receipt, ["final", "status"]) == "policy_failed_closed"

    assert [
             %{
               "kind" => "tool_selector",
               "rule_id" => "block-shell-while-reviewing",
               "action" => "block"
             }
           ] = get_in(shell_receipt, ["decision", "policy_actions"])

    approve_request =
      tool_request("sequence-state-session", "review", "approve_tool_result", "planning",
        content: "review passed"
      )

    approve_conn = call(:post, "/v1/synthetic/simulate", %{request: approve_request})
    approve_receipt = approve_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert [
             %{
               "kind" => "tool_sequence",
               "rule_id" => "leave-untrusted-review",
               "action" => "state_transition",
               "state_transition" => "active"
             }
           ] = get_in(approve_receipt, ["decision", "policy_actions"])

    allowed_shell = call(:post, "/v1/synthetic/simulate", %{request: shell_request})
    allowed_receipt = allowed_shell.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(allowed_receipt, ["final", "status"]) == "simulated"
    assert get_in(allowed_receipt, ["decision", "policy_actions"]) == []
  end

  test "tool sequence enforces before-after windows and reset tool events" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 12, "recent_limit" => 12})
      |> Map.put("targets", [%{"model" => "local/read", "context_window" => 512}])
      |> Map.put("governance", [
        %{
          "id" => "browser-before-shell",
          "kind" => "tool_sequence",
          "cache_scope" => "session_id",
          "after" => %{
            "tool" => %{"namespace" => "browser", "phase" => "result_interpretation"}
          },
          "within" => %{"turns" => 1},
          "until" => %{"tool" => %{"namespace" => "review", "name" => "approve_tool_result"}},
          "then" => %{
            "action" => "block",
            "tool" => %{
              "namespace" => "shell",
              "name" => "exec",
              "phase" => "planning",
              "risk_class" => "irreversible"
            }
          }
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    browser_result =
      tool_request("sequence-direct-session", "browser", "read_page", "result_interpretation",
        risk_class: "read_only"
      )

    shell_request =
      tool_request("sequence-direct-session", "shell", "exec", "planning",
        risk_class: "irreversible"
      )

    call(:post, "/v1/synthetic/simulate", %{request: browser_result})
    blocked_shell = call(:post, "/v1/synthetic/simulate", %{request: shell_request})
    blocked_receipt = blocked_shell.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(blocked_receipt, ["final", "status"]) == "policy_failed_closed"

    assert [
             %{
               "kind" => "tool_sequence",
               "rule_id" => "browser-before-shell",
               "action" => "block",
               "sequence_after_key" => "browser:read_page:result_interpretation"
             }
           ] = get_in(blocked_receipt, ["decision", "policy_actions"])

    review_reset =
      tool_request("sequence-reset-session", "review", "approve_tool_result", "planning")

    reset_browser =
      tool_request("sequence-reset-session", "browser", "read_page", "result_interpretation",
        risk_class: "read_only"
      )

    reset_shell =
      tool_request("sequence-reset-session", "shell", "exec", "planning",
        risk_class: "irreversible"
      )

    call(:post, "/v1/synthetic/simulate", %{request: reset_browser})
    call(:post, "/v1/synthetic/simulate", %{request: review_reset})
    reset_conn = call(:post, "/v1/synthetic/simulate", %{request: reset_shell})
    reset_receipt = reset_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(reset_receipt, ["final", "status"]) == "simulated"
    assert get_in(reset_receipt, ["decision", "policy_actions"]) == []

    expired_browser =
      tool_request("sequence-expired-session", "browser", "read_page", "result_interpretation",
        risk_class: "read_only"
      )

    unrelated_tool =
      tool_request("sequence-expired-session", "browser", "search", "planning",
        risk_class: "read_only"
      )

    expired_shell =
      tool_request("sequence-expired-session", "shell", "exec", "planning",
        risk_class: "irreversible"
      )

    call(:post, "/v1/synthetic/simulate", %{request: expired_browser})
    call(:post, "/v1/synthetic/simulate", %{request: unrelated_tool})
    expired_conn = call(:post, "/v1/synthetic/simulate", %{request: expired_shell})
    expired_receipt = expired_conn.resp_body |> Jason.decode!() |> get_in(["receipt"])

    assert get_in(expired_receipt, ["final", "status"]) == "simulated"
    assert get_in(expired_receipt, ["decision", "policy_actions"]) == []
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

    [event | _] = Wardwright.PolicyCache.recent(%{"kind" => "tool_call"}, 1)
    assert get_in(event, ["value", "primary_tool", "name"]) == "run_shell"
    refute inspect(event) =~ "secret-token-123"
  end

  defp tool_request(session_id, namespace, name, phase, opts \\ []) do
    %{
      model: "unit-model",
      metadata: %{
        session_id: session_id,
        tool_context: %{
          phase: phase,
          primary_tool: %{
            namespace: namespace,
            name: name,
            risk_class: Keyword.get(opts, :risk_class, "unknown")
          }
        }
      },
      messages: [%{role: "user", content: Keyword.get(opts, :content, "#{namespace}.#{name}")}]
    }
  end
end
