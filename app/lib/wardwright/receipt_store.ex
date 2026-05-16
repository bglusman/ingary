defmodule Wardwright.ReceiptStore do
  @moduledoc false

  use Agent

  @contract_version "storage-contract-v0"
  @migration_version 1

  def start_link(_opts) do
    Agent.start_link(fn -> %{receipts: %{}} end, name: __MODULE__)
  end

  def insert(receipt) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:receipts, receipt["receipt_id"]], receipt)
    end)

    Wardwright.Runtime.Events.publish(Wardwright.Runtime.Events.topic(:receipts), %{
      "type" => "receipt.stored",
      "receipt_id" => receipt["receipt_id"],
      "synthetic_model" => receipt["synthetic_model"],
      "synthetic_version" => receipt["synthetic_version"],
      "session_id" => sourced_value(receipt, ["caller", "session_id"]),
      "run_id" => sourced_value(receipt, ["caller", "run_id"]) || receipt["run_id"],
      "status" => get_in(receipt, ["final", "status"]),
      "simulation" => receipt["simulation"] || false,
      "created_at" => receipt["created_at"]
    })

    receipt
  end

  def list(filters \\ %{}, limit \\ 50) do
    limit = limit |> max(1) |> min(500)

    Agent.get(__MODULE__, fn state ->
      state.receipts
      |> Map.values()
      |> Enum.filter(&matches?(&1, filters))
      |> Enum.sort_by(&sort_key/1, :desc)
      |> Enum.take(limit)
      |> Enum.map(&summary/1)
    end)
  end

  def get(receipt_id) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.receipts, receipt_id)
    end)
  end

  def clear do
    Agent.update(__MODULE__, fn _ -> %{receipts: %{}} end)
  end

  def health do
    %{
      "kind" => "memory",
      "contract_version" => @contract_version,
      "migration_version" => @migration_version,
      "read_health" => "ok",
      "write_health" => "ok",
      "capabilities" => %{
        "durable" => false,
        "transactional" => true,
        "concurrent_writers" => false,
        "json_queries" => true,
        "event_replay" => true,
        "time_range_indexes" => false,
        "retention_jobs" => false
      }
    }
  end

  def metadata, do: health()

  def summary(receipt) do
    %{
      "receipt_id" => receipt["receipt_id"],
      "created_at" => receipt["created_at"],
      "receipt_schema" => receipt["receipt_schema"],
      "synthetic_model" => receipt["synthetic_model"],
      "synthetic_version" => receipt["synthetic_version"],
      "caller" => receipt["caller"] || %{},
      "tenant_id" => sourced_value(receipt, ["caller", "tenant_id"]),
      "application_id" => sourced_value(receipt, ["caller", "application_id"]),
      "consuming_agent_id" => sourced_value(receipt, ["caller", "consuming_agent_id"]),
      "consuming_user_id" => sourced_value(receipt, ["caller", "consuming_user_id"]),
      "session_id" => sourced_value(receipt, ["caller", "session_id"]),
      "run_id" => sourced_value(receipt, ["caller", "run_id"]) || receipt["run_id"],
      "selected_provider" => selected_provider(receipt),
      "selected_model" => get_in(receipt, ["decision", "selected_model"]),
      "status" => get_in(receipt, ["final", "status"]),
      "simulation" => receipt["simulation"] || false,
      "stream_policy_action" => get_in(receipt, ["final", "stream_policy_action"])
    }
    |> put_if_present(
      "tool_namespace",
      get_in(receipt, ["decision", "tool_context", "primary_tool", "namespace"])
    )
    |> put_if_present(
      "tool_name",
      get_in(receipt, ["decision", "tool_context", "primary_tool", "name"])
    )
    |> put_if_present("tool_phase", get_in(receipt, ["decision", "tool_context", "phase"]))
    |> put_if_present(
      "tool_risk_class",
      get_in(receipt, ["decision", "tool_context", "primary_tool", "risk_class"])
    )
    |> put_if_present("tool_policy_status", get_in(receipt, ["final", "tool_policy", "status"]))
  end

  defp matches?(receipt, filters) do
    summary = summary(receipt)

    Enum.all?(filters, fn
      {"model", value} ->
        with {:ok, model} <- Wardwright.normalize_model(value) do
          summary["synthetic_model"] == model
        else
          _ -> false
        end

      {"created_at_min", value} ->
        compare_int(summary["created_at"], value, &>=/2)

      {"created_at_max", value} ->
        compare_int(summary["created_at"], value, &<=/2)

      {"simulation", value} ->
        boolean_value(value) == summary["simulation"]

      {key, value}
      when key in [
             "tenant_id",
             "application_id",
             "consuming_agent_id",
             "consuming_user_id",
             "session_id",
             "run_id",
             "synthetic_model",
             "synthetic_version",
             "selected_provider",
             "selected_model",
             "status",
             "stream_policy_action",
             "tool_namespace",
             "tool_name",
             "tool_phase",
             "tool_risk_class",
             "tool_policy_status"
           ] ->
        summary[key] == value

      {_key, ""} ->
        true

      {_key, _value} ->
        true
    end)
  end

  defp sourced_value(receipt, path) do
    receipt
    |> get_in(path)
    |> case do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp selected_provider(receipt) do
    get_in(receipt, ["decision", "selected_provider"]) ||
      get_in(receipt, ["decision", "selected_model"]) |> provider_from_model()
  end

  defp provider_from_model(model) when is_binary(model) do
    model |> String.split("/", parts: 2) |> List.first()
  end

  defp provider_from_model(_), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp sort_key(receipt), do: {receipt["created_at"] || 0, receipt["receipt_id"] || ""}

  defp compare_int(left, right, comparator) when is_integer(left) do
    case integer_value(right) do
      nil -> false
      value -> comparator.(left, value)
    end
  end

  defp compare_int(_left, _right, _comparator), do: false

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_value(_), do: nil

  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value("true"), do: true
  defp boolean_value("false"), do: false
  defp boolean_value(_), do: nil
end
