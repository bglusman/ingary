defmodule ElixirIngaryTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  @opts ElixirIngary.Router.init([])

  setup do
    ElixirIngary.ReceiptStore.clear()
    :ok
  end

  test "lists flat and prefixed public models" do
    conn = call(:get, "/v1/models")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Enum.map(body["data"], & &1["id"]) == ["coding-balanced", "ingary/coding-balanced"]
  end

  test "chat completion records caller headers and selected model" do
    request = %{
      model: "ingary/coding-balanced",
      messages: [%{role: "user", content: "hello"}],
      metadata: %{consuming_agent_id: "body-agent"}
    }

    conn =
      :post
      |> call("/v1/chat/completions", request, [{"x-ingary-agent-id", "header-agent"}])

    assert conn.status == 200
    assert get_resp_header(conn, "x-ingary-selected-model") == ["local/qwen-coder"]
    [receipt_id] = get_resp_header(conn, "x-ingary-receipt-id")

    receipt = ElixirIngary.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["caller", "consuming_agent_id"]) == %{
             "value" => "header-agent",
             "source" => "header"
           }
  end

  test "simulation can select the managed model for large prompts" do
    request = %{
      request: %{
        model: "coding-balanced",
        messages: [%{role: "user", content: String.duplicate("x", 140_000)}]
      }
    }

    conn = call(:post, "/v1/synthetic/simulate", request)
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["receipt", "decision", "selected_model"]) == "managed/kimi-k2.6"
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    encoded = if is_nil(body), do: nil, else: Jason.encode!(body)

    method
    |> conn(path, encoded)
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    end)
    |> ElixirIngary.Router.call(@opts)
  end
end
