defmodule Wardwright.MCPAuthoringTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import Phoenix.ConnTest

  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  @endpoint WardwrightWeb.Endpoint

  setup_all do
    original_config = Application.get_env(:wardwright, WardwrightWeb.Endpoint, [])

    endpoint_config =
      Keyword.merge(original_config,
        http: [ip: {127, 0, 0, 1}, port: 0],
        server: false,
        secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
      )

    Application.put_env(:wardwright, WardwrightWeb.Endpoint, endpoint_config)
    start_supervised!(WardwrightWeb.Endpoint)

    on_exit(fn ->
      Application.put_env(:wardwright, WardwrightWeb.Endpoint, original_config)
    end)

    :ok
  end

  test "Hermes MCP server exposes policy authoring tools" do
    tool_names =
      WardwrightWeb.MCPServer.__components__(:tool)
      |> Enum.map(& &1.name)

    assert tool_names == [
             "explain_projection",
             "simulate_policy",
             "validate_policy_artifact"
           ]
  end

  test "projection tool returns deterministic projection payloads" do
    assert {:reply, %Response{} = response, %Frame{}} =
             WardwrightWeb.MCP.Tools.ExplainProjection.execute(
               %{"pattern_id" => "tts-retry"},
               Frame.new()
             )

    assert get_in(response.structured_content, ["projection", "state_machine", "initial_state"]) ==
             "observing"
  end

  test "projection tool fails closed for unknown policy patterns" do
    assert {:error, error, %Frame{}} =
             WardwrightWeb.MCP.Tools.ExplainProjection.execute(
               %{"pattern_id" => "not-real"},
               Frame.new()
             )

    assert error.reason == :execution_error
    assert error.message == "policy pattern not found"
    assert error.data == %{pattern_id: "not-real"}
  end

  test "validation tool reuses the artifact validator contract" do
    assert {:reply, %Response{} = response, %Frame{}} =
             WardwrightWeb.MCP.Tools.ValidatePolicyArtifact.execute(%{}, Frame.new())

    assert response.structured_content["schema"] == "wardwright.policy_validation.v1"
    assert response.structured_content["source"] == "current_config"
  end

  test "streamable HTTP transport initializes and lists tools through the Phoenix mount" do
    initialize =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post(
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "wardwright-test", "version" => "0"}
          }
        })
      )

    assert initialize.status == 200

    assert %{"result" => %{"serverInfo" => %{"name" => "wardwright-policy-authoring"}}} =
             Jason.decode!(initialize.resp_body)

    [session_id] = get_resp_header(initialize, "mcp-session-id")

    initialized =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-session-id", session_id)
      |> post(
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized",
          "params" => %{}
        })
      )

    assert initialized.status == 202

    listed =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-session-id", session_id)
      |> post(
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        })
      )

    assert listed.status == 200

    tool_names =
      listed.resp_body
      |> Jason.decode!()
      |> get_in(["result", "tools"])
      |> Enum.map(& &1["name"])

    assert tool_names == [
             "explain_projection",
             "simulate_policy",
             "validate_policy_artifact"
           ]
  end

  test "protected access plug rejects non-local callers without an admin token" do
    original_prototype_access = Application.get_env(:wardwright, :allow_prototype_access)
    original_admin_token = Application.get_env(:wardwright, :admin_token)

    Application.put_env(:wardwright, :allow_prototype_access, false)
    Application.delete_env(:wardwright, :admin_token)

    on_exit(fn ->
      restore_env(:allow_prototype_access, original_prototype_access)
      restore_env(:admin_token, original_admin_token)
    end)

    rejected =
      conn(:post, "/mcp", "{}")
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> WardwrightWeb.ProtectedAccess.call([])

    assert rejected.status == 403
    assert rejected.halted
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == "protected_endpoint"
  end

  defp restore_env(key, nil), do: Application.delete_env(:wardwright, key)
  defp restore_env(key, value), do: Application.put_env(:wardwright, key, value)
end
