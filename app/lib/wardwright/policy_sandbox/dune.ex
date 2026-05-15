defmodule Wardwright.PolicySandbox.Dune do
  @moduledoc """
  Thin Dune adapter for evaluating BEAM-native policy snippets.

  This is an evaluation spike, not a promise that Dune is a hostile-code
  security boundary. The adapter normalizes Dune's result into policy-engine
  terms so callers can fail closed and record receipts without matching on
  Dune structs directly.
  """

  @default_opts [
    timeout: 250,
    max_reductions: 10_000,
    max_heap_size: 20_000,
    inspect_sort_maps: true
  ]

  def default_opts, do: @default_opts

  def eval_string(source, opts \\ []) when is_binary(source) and is_list(opts) do
    source
    |> Dune.eval_string(Keyword.merge(@default_opts, opts))
    |> normalize_result()
  end

  def parse_string(source, opts \\ []) when is_binary(source) and is_list(opts) do
    source
    |> Dune.string_to_quoted(Keyword.merge(@default_opts, opts))
    |> normalize_result()
  end

  defp normalize_result(%Dune.Success{} = success) do
    %{
      "engine" => "dune",
      "status" => "ok",
      "value" => success.value,
      "inspected" => success.inspected,
      "stdio" => success.stdio
    }
  end

  defp normalize_result(%Dune.Failure{} = failure) do
    %{
      "engine" => "dune",
      "status" => "error",
      "reason" => Atom.to_string(failure.type),
      "message" => failure.message,
      "stdio" => failure.stdio
    }
  end
end
