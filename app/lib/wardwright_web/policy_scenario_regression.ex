defmodule WardwrightWeb.PolicyScenarioRegression do
  @moduledoc false

  @schema "wardwright.policy_regression_pack.v1"

  def exunit_source(pack) when is_map(pack) do
    with :ok <- validate_pack(pack),
         {:ok, encoded_pack} <- Jason.encode(pack) do
      {:ok, render_exunit(pack, Base.encode64(encoded_pack))}
    else
      {:error, %Jason.EncodeError{} = error} -> {:error, Exception.message(error)}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  def exunit_source(_pack), do: {:error, "regression pack must be a JSON object"}

  defp validate_pack(pack) do
    cond do
      Map.get(pack, "schema") != @schema ->
        {:error, "regression pack schema must be #{@schema}"}

      not is_binary(Map.get(pack, "pattern_id")) ->
        {:error, "regression pack pattern_id must be a string"}

      not is_list(Map.get(pack, "scenarios")) ->
        {:error, "regression pack scenarios must be a list"}

      true ->
        :ok
    end
  end

  defp render_exunit(pack, encoded_pack) do
    module_name = generated_module_name(Map.fetch!(pack, "pattern_id"))

    """
    defmodule #{module_name} do
      use ExUnit.Case, async: true

      @regression_pack "#{encoded_pack}"
                       |> Base.decode64!()
                       |> Jason.decode!()

      def regression_pack, do: @regression_pack

      def validate_pack! do
        pattern_id = @regression_pack["pattern_id"]
        known_state_ids = Wardwright.PolicyProjection.state_ids(pattern_id) |> MapSet.new()

        for scenario <- @regression_pack["scenarios"] do
          assert scenario["pattern_id"] == pattern_id
          assert scenario["pinned"] == true
          assert {:ok, parsed} = Wardwright.PolicyScenario.from_map(scenario, pattern_id)

          trace_state_ids =
            parsed
            |> Wardwright.PolicyScenario.trace_state_ids()
            |> MapSet.new()

          assert MapSet.subset?(trace_state_ids, known_state_ids)
        end

        :ok
      end

      test "pack schema and scenario count remain coherent" do
        assert @regression_pack["schema"] == "#{@schema}"
        assert @regression_pack["scenario_count"] == length(@regression_pack["scenarios"])
        assert @regression_pack["scenario_count"] > 0
      end

      test "pinned scenarios still validate against the current projection contract" do
        assert :ok = validate_pack!()
      end
    end
    """
  end

  defp generated_module_name(pattern_id) do
    suffix =
      pattern_id
      |> String.replace(~r/[^a-zA-Z0-9]+/, " ")
      |> String.split()
      |> Enum.map_join("", &capitalize_part/1)
      |> case do
        "" -> "Default"
        value -> value
      end

    "Wardwright.Generated.PolicyRegression.#{suffix}Test"
  end

  defp capitalize_part(<<first::binary-size(1), rest::binary>>) do
    String.upcase(first) <> String.downcase(rest)
  end
end
