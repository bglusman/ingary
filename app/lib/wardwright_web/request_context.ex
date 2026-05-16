defmodule WardwrightWeb.RequestContext do
  @moduledoc false

  import Plug.Conn

  @cache_scope_keys [
    "tenant_id",
    "application_id",
    "consuming_agent_id",
    "consuming_user_id",
    "session_id",
    "run_id"
  ]

  def caller(conn, metadata) when is_map(metadata) do
    %{}
    |> put_sourced(
      "tenant_id",
      header_or_metadata(conn, metadata, "x-wardwright-tenant-id", "tenant_id")
    )
    |> put_sourced(
      "application_id",
      header_or_metadata(conn, metadata, "x-wardwright-application-id", "application_id")
    )
    |> put_sourced(
      "consuming_agent_id",
      header_or_metadata(conn, metadata, "x-wardwright-agent-id", "consuming_agent_id") ||
        header_or_metadata(conn, metadata, "x-wardwright-agent-id", "agent_id")
    )
    |> put_sourced(
      "consuming_user_id",
      header_or_metadata(conn, metadata, "x-wardwright-user-id", "consuming_user_id") ||
        header_or_metadata(conn, metadata, "x-wardwright-user-id", "user_id")
    )
    |> put_sourced(
      "session_id",
      header_or_metadata(conn, metadata, "x-wardwright-session-id", "session_id")
    )
    |> put_sourced("run_id", header_or_metadata(conn, metadata, "x-wardwright-run-id", "run_id"))
    |> put_sourced(
      "client_request_id",
      header_or_metadata(conn, metadata, "x-client-request-id", "client_request_id")
    )
    |> Map.put("tags", metadata_tags(metadata))
  end

  def caller(conn, _metadata), do: caller(conn, %{})

  def session_id(caller), do: get_in(caller, ["session_id", "value"])

  def tool_context_opts(conn), do: [trusted_metadata: trusted_tool_context_metadata?(conn)]

  def trusted_tool_context_metadata?(conn) do
    local_request?(conn) or admin_token_valid?(conn) or
      Application.get_env(:wardwright, :allow_prototype_access, false)
  end

  def cache_scope_from_query(params) do
    Enum.reduce(@cache_scope_keys, %{}, fn key, acc ->
      case params |> Map.get(key) |> blank_to_nil() do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  def metadata_string(value) when is_binary(value), do: String.trim(value)
  def metadata_string(value) when is_integer(value), do: Integer.to_string(value)
  def metadata_string(value) when is_float(value), do: Float.to_string(value)
  def metadata_string(value) when is_boolean(value), do: to_string(value)
  def metadata_string(_), do: ""

  def blank_to_nil(nil), do: nil
  def blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp header_or_metadata(conn, metadata, header_name, metadata_key) do
    case conn |> get_req_header(header_name) |> List.first() |> blank_to_nil() do
      nil ->
        metadata
        |> Map.get(metadata_key)
        |> metadata_string()
        |> blank_to_nil()
        |> case do
          nil -> nil
          value -> %{"value" => value, "source" => "body_metadata"}
        end

      value ->
        %{"value" => value, "source" => "header"}
    end
  end

  defp put_sourced(map, _key, nil), do: map
  defp put_sourced(map, key, value), do: Map.put(map, key, value)

  defp metadata_tags(%{"tags" => tags}) when is_list(tags) do
    tags
    |> Enum.map(&metadata_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp metadata_tags(%{"tags" => tags}) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp metadata_tags(_), do: []

  defp local_request?(%{remote_ip: {127, 0, 0, 1}}), do: true
  defp local_request?(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp local_request?(_conn), do: false

  defp admin_token_valid?(conn) do
    case {admin_token(), request_admin_token(conn)} do
      {token, request_token} when is_binary(token) and is_binary(request_token) ->
        Plug.Crypto.secure_compare(token, request_token)

      {_token, _request_token} ->
        false
    end
  rescue
    _error -> false
  end

  defp admin_token do
    (Application.get_env(:wardwright, :admin_token) || System.get_env("WARDWRIGHT_ADMIN_TOKEN"))
    |> metadata_string()
    |> blank_to_nil()
  end

  defp request_admin_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> bearer_token()
    |> case do
      nil ->
        conn
        |> get_req_header("x-wardwright-admin-token")
        |> List.first()
        |> metadata_string()
        |> blank_to_nil()

      token ->
        token
    end
  end

  defp bearer_token("Bearer " <> token), do: blank_to_nil(token)
  defp bearer_token("bearer " <> token), do: blank_to_nil(token)
  defp bearer_token(_value), do: nil
end
