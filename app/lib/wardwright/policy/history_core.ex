defmodule Wardwright.Policy.HistoryCore do
  @moduledoc false

  def count_recent_matches(matches, opts \\ []) when is_list(matches) do
    recent_limit = Keyword.get(opts, :recent_limit, length(matches))
    threshold = Keyword.get(opts, :threshold, 1)
    scope = Keyword.get(opts, :scope, "history")

    matches
    |> count_decision(
      threshold: threshold,
      recent_limit: recent_limit,
      working_set_size: length(matches),
      scope: scope
    )
    |> decision_count()
  end

  def count_decision(matches, opts) when is_list(matches) do
    threshold = integer_value(Keyword.fetch!(opts, :threshold))
    recent_limit = integer_value(Keyword.fetch!(opts, :recent_limit))
    working_set_size = integer_value(Keyword.fetch!(opts, :working_set_size))
    scope = to_string(Keyword.fetch!(opts, :scope))

    :wardwright@history_core.count_matches(
      matches,
      threshold,
      recent_limit,
      working_set_size,
      scope
    )
  end

  def triggered_count?(count, threshold) do
    count = max(0, integer_value(count))

    count
    |> then(&List.duplicate(true, &1))
    |> count_decision(
      threshold: threshold,
      recent_limit: max(count, 1),
      working_set_size: count,
      scope: "history"
    )
    |> triggered?()
  end

  def triggered?({:triggered, _scope, _count, _threshold, _recent_limit, _working_set_size}),
    do: true

  def triggered?({:not_triggered, _scope, _count, _threshold, _recent_limit, _working_set_size}),
    do: false

  def decision_count({_status, _scope, count, _threshold, _recent_limit, _working_set_size}),
    do: count

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: 0
end
