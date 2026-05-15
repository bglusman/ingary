defmodule Wardwright.RoutePlannerTest do
  use Wardwright.RouterCase

  test "dispatcher selects the smallest fitting model and preserves larger fallbacks" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "small/model", "context_window" => 16},
          %{"model" => "medium/model", "context_window" => 64},
          %{"model" => "large/model", "context_window" => 256}
        ],
        "route_root" => "fit-dispatcher",
        "dispatchers" => [
          %{"id" => "fit-dispatcher", "models" => ["small/model", "medium/model", "large/model"]}
        ]
      })

    assert %{
             route_type: "dispatcher",
             selected_model: "medium/model",
             selected_models: ["medium/model", "large/model"],
             fallback_models: ["large/model"],
             skipped: [%{"target" => "small/model", "reason" => "context_window_too_small"}]
           } = Wardwright.select_route(32)
  end

  test "cascade keeps declaration order while skipping oversized targets" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "fast/model", "context_window" => 16},
          %{"model" => "steady/model", "context_window" => 128},
          %{"model" => "reserve/model", "context_window" => 256}
        ],
        "route_root" => "local-then-reserve",
        "cascades" => [
          %{
            "id" => "local-then-reserve",
            "models" => ["fast/model", "steady/model", "reserve/model"]
          }
        ]
      })

    assert %{
             route_type: "cascade",
             selected_model: "steady/model",
             selected_models: ["steady/model", "reserve/model"],
             fallback_models: ["reserve/model"],
             skipped: [%{"target" => "fast/model"}]
           } = Wardwright.select_route(96)
  end

  test "partial alloys use overlapping constituents until smaller contexts stop fitting" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "local/qwen", "context_window" => 32},
          %{"model" => "managed/kimi", "context_window" => 256}
        ],
        "route_root" => "local-kimi-partial",
        "alloys" => [
          %{
            "id" => "local-kimi-partial",
            "strategy" => "deterministic_all",
            "partial_context" => true,
            "constituents" => ["local/qwen", "managed/kimi"]
          }
        ]
      })

    assert %{
             route_type: "alloy",
             combine_strategy: "deterministic_all",
             selected_model: "local/qwen",
             selected_models: ["local/qwen", "managed/kimi"],
             skipped: []
           } = Wardwright.select_route(16)

    assert %{
             route_type: "alloy",
             combine_strategy: "deterministic_all",
             selected_model: "managed/kimi",
             selected_models: ["managed/kimi"],
             skipped: [%{"target" => "local/qwen", "reason" => "context_window_too_small"}]
           } = Wardwright.select_route(96)
  end

  test "weighted alloys respect weights and expose the selected plan in receipts" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "cheap/model", "context_window" => 128},
          %{"model" => "strong/model", "context_window" => 128}
        ],
        "route_root" => "weighted-blend",
        "alloys" => [
          %{
            "id" => "weighted-blend",
            "strategy" => "weighted",
            "min_context_window" => 128,
            "constituents" => [
              %{"model" => "cheap/model", "weight" => 1},
              %{"model" => "strong/model", "weight" => 100}
            ]
          }
        ]
      })

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "small prompt"}]
        }
      })

    assert conn.status == 200
    receipt = Jason.decode!(conn.resp_body)["receipt"]

    assert get_in(receipt, ["decision", "route_type"]) == "alloy"
    assert get_in(receipt, ["decision", "strategy"]) == "weighted"
    assert get_in(receipt, ["decision", "selected_model"]) == "strong/model"
    assert get_in(receipt, ["decision", "selected_models"]) == ["strong/model", "cheap/model"]
  end
end
