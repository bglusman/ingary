defmodule Wardwright.ToolContextTest do
  use ExUnit.Case, async: true

  test "normalizes OpenAI-style tool choice and declared schema evidence" do
    {_request, context} =
      Wardwright.ToolContext.normalize_request(%{
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "create_ticket",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"title" => %{"type" => "string"}}
              }
            }
          }
        ],
        "tool_choice" => %{
          "type" => "function",
          "function" => %{"name" => "create_ticket"}
        },
        "messages" => [%{"role" => "user", "content" => "file this incident"}]
      })

    assert context["schema"] == "wardwright.tool_context.v1"
    assert context["phase"] == "planning"
    assert context["confidence"] == "exact"

    assert context["primary_tool"] == %{
             "namespace" => "openai.function",
             "name" => "create_ticket",
             "source" => "tool_choice",
             "risk_class" => "unknown"
           }

    assert get_in(context, ["available_tools", Access.at(0), "schema_hash"]) =~ "sha256:"
    assert Wardwright.ToolContext.cache_key(context) == "openai.function:create_ticket:planning"

    assert Wardwright.ToolContext.matches?(context, %{
             "namespace" => "openai.function",
             "name" => "create_ticket",
             "phase" => "planning"
           })

    refute Wardwright.ToolContext.matches?(context, %{"risk_class" => "write"})
  end

  test "normalizes assistant tool calls without preserving raw arguments or results" do
    raw_argument = ~s({"command":"echo secret-token-123"})
    raw_result = "created secret-token-123"

    context =
      Wardwright.ToolContext.normalize(%{
        "messages" => [
          %{"role" => "user", "content" => "prepare the command"},
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_secret",
                "type" => "function",
                "function" => %{"name" => "run_shell", "arguments" => raw_argument}
              }
            ]
          },
          %{"role" => "tool", "tool_call_id" => "call_secret", "content" => raw_result}
        ]
      })

    assert context["phase"] == "result_interpretation"
    assert context["tool_call_id"] == "call_secret"
    assert context["argument_hash"] =~ "sha256:"
    assert context["result_hash"] =~ "sha256:"
    assert context["result_status"] == "unknown"
    assert get_in(context, ["primary_tool", "name"]) == "run_shell"

    refute inspect(context) =~ "secret-token-123"
    refute inspect(context) =~ raw_argument
    refute inspect(context) =~ raw_result
  end

  test "normalizes caller metadata into a bounded contract shape" do
    {request, context} =
      Wardwright.ToolContext.normalize_request(
        %{
          "metadata" => %{
            "tool_context" => %{
              "schema" => "caller-controlled",
              "phase" => "planning",
              "primary_tool" => %{
                "namespace" => "mcp.github",
                "name" => "create_pull_request",
                "risk_class" => "write",
                "source" => "unexpected"
              },
              "tool_call_id" => 42,
              "argument_hash" => "raw secret argument",
              "result_hash" => "raw secret result",
              "available_tools" => [
                %{"namespace" => "mcp.github", "name" => "create_pull_request"}
              ],
              "confidence" => "unexpected"
            }
          }
        },
        trusted_metadata: true
      )

    assert context["schema"] == "wardwright.tool_context.v1"
    assert context["tool_call_id"] == "42"
    assert context["argument_hash"] =~ "sha256:"
    assert context["result_hash"] =~ "sha256:"
    assert context["confidence"] == "declared"
    assert get_in(context, ["primary_tool", "source"]) == "caller_metadata"
    assert get_in(request, ["metadata", "tool_context"]) == context
    refute inspect(context) =~ "raw secret"

    assert Wardwright.ToolContext.matches?(context, %{
             "namespaces" => ["mcp.github"],
             "names" => ["create_pull_request"],
             "risk_classes" => ["read_only", "write"]
           })
  end

  test "ignores caller metadata unless the gateway marks it trusted" do
    request = %{
      "metadata" => %{
        "tool_context" => %{
          "phase" => "planning",
          "primary_tool" => %{"namespace" => "mcp.github", "name" => "create_pull_request"}
        }
      }
    }

    assert Wardwright.ToolContext.normalize(request) == nil

    assert get_in(
             Wardwright.ToolContext.normalize(request, trusted_metadata: true),
             ["primary_tool", "name"]
           ) == "create_pull_request"
  end

  test "does not produce partial cache keys for incomplete identities" do
    refute Wardwright.ToolContext.cache_key(%{
             "phase" => "planning",
             "primary_tool" => %{"name" => "create_pull_request"}
           })
  end
end
