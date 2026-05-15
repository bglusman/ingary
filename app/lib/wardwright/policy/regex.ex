defmodule Wardwright.Policy.Regex do
  @moduledoc false

  def match?(_text, pattern) when pattern in [nil, ""], do: false

  def match?(text, pattern) when is_binary(text) and is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, text)
      {:error, _} -> false
    end
  end

  def match?(_text, _pattern), do: false

  def count_matches(events, pattern) when is_list(events) do
    Enum.count(events, fn event ->
      text =
        get_in(event, ["value", "text"]) ||
          get_in(event, ["value", "content"]) ||
          Map.get(event, "key", "")

      __MODULE__.match?(to_string(text), pattern)
    end)
  end
end
