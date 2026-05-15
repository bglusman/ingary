defmodule Wardwright.PolicySandbox.Wasm do
  @moduledoc """
  Fail-closed WASM policy adapter boundary.

  This module establishes the policy-engine ABI before committing the runtime
  dependency. WASM is the intended boundary for untrusted portable policies, but
  until a Wasmex integration is wired and budgeted, evaluation blocks with a
  typed result instead of silently allowing policy execution to continue.
  """

  def evaluate(_policy) do
    %{
      "engine" => "wasm",
      "status" => "error",
      "action" => "block",
      "reason" => "wasm policy runtime is not enabled",
      "trace" => [
        %{
          "rule" => "wasm-runtime",
          "result" => false,
          "reason" => "runtime_unavailable"
        }
      ]
    }
  end
end
