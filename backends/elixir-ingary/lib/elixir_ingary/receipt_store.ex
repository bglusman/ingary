defmodule ElixirIngary.ReceiptStore do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def insert(receipt) do
    Agent.update(__MODULE__, &[receipt | &1])
    receipt
  end

  def list(filters \\ %{}, limit \\ 50) do
    limit = limit |> max(1) |> min(500)

    Agent.get(__MODULE__, fn receipts ->
      receipts
      |> Enum.filter(&matches?(&1, filters))
      |> Enum.take(limit)
    end)
  end

  def get(receipt_id) do
    Agent.get(__MODULE__, fn receipts ->
      Enum.find(receipts, &(&1["receipt_id"] == receipt_id))
    end)
  end

  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end

  defp matches?(receipt, filters) do
    Enum.all?(filters, fn
      {"model", value} ->
        with {:ok, model} <- ElixirIngary.normalize_model(value) do
          receipt["synthetic_model"] == model
        else
          _ -> false
        end

      {"consuming_agent_id", value} ->
        sourced_value(receipt, ["caller", "consuming_agent_id"]) == value

      {"consuming_user_id", value} ->
        sourced_value(receipt, ["caller", "consuming_user_id"]) == value

      {"session_id", value} ->
        sourced_value(receipt, ["caller", "session_id"]) == value

      {"run_id", value} ->
        receipt["run_id"] == value

      {"status", value} ->
        get_in(receipt, ["final", "status"]) == value

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
end
