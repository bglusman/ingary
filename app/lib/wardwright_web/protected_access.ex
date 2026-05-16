defmodule WardwrightWeb.ProtectedAccess do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] ->
        conn

      admin_token_valid?(conn) ->
        conn

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{
            error: %{
              code: "protected_endpoint",
              message: "protected endpoint requires localhost or admin token",
              type: "forbidden"
            }
          })
        )
        |> halt()
    end
  end

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
    Application.get_env(:wardwright, :admin_token)
    |> fallback_to_env()
    |> metadata_string()
    |> blank_to_nil()
  end

  defp fallback_to_env(nil), do: System.get_env("WARDWRIGHT_ADMIN_TOKEN")
  defp fallback_to_env(value), do: value

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

  defp bearer_token("Bearer " <> token), do: token |> metadata_string() |> blank_to_nil()
  defp bearer_token(_value), do: nil

  defp metadata_string(nil), do: nil
  defp metadata_string(value) when is_binary(value), do: String.trim(value)
  defp metadata_string(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()

  defp metadata_string(value) when is_integer(value),
    do: value |> Integer.to_string() |> String.trim()

  defp metadata_string(_value), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
