defmodule Wardwright.Policy.CoreRuntime do
  @moduledoc false

  @modes [:gleam, :elixir, :compare]

  def dispatch(label, gleam_fun, elixir_fun)
      when is_function(gleam_fun, 0) and is_function(elixir_fun, 0) do
    case mode() do
      :gleam ->
        gleam_fun.()

      :elixir ->
        elixir_fun.()

      :compare ->
        gleam = gleam_fun.()
        elixir = elixir_fun.()

        if gleam == elixir do
          gleam
        else
          raise ArgumentError,
                "policy core mismatch for #{label}: gleam=#{inspect(gleam)} elixir=#{inspect(elixir)}"
        end
    end
  end

  def mode do
    Process.get(:wardwright_policy_core) ||
      :wardwright
      |> Application.get_env(:policy_core)
      |> normalize_mode()
      |> case do
        nil -> System.get_env("WARDWRIGHT_POLICY_CORE", "gleam") |> normalize_mode()
        mode -> mode
      end
  end

  def with_core(mode, fun) when is_function(fun, 0) do
    previous = Process.get(:wardwright_policy_core)
    Process.put(:wardwright_policy_core, normalize_mode(mode) || :gleam)

    try do
      fun.()
    after
      if previous,
        do: Process.put(:wardwright_policy_core, previous),
        else: Process.delete(:wardwright_policy_core)
    end
  end

  defp normalize_mode(mode) when mode in @modes, do: mode
  defp normalize_mode(mode) when is_atom(mode), do: nil

  defp normalize_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "gleam" -> :gleam
      "elixir" -> :elixir
      "compare" -> :compare
      _ -> nil
    end
  end

  defp normalize_mode(_mode), do: nil
end
