---
title: Starlark Policy Engine Spike Contract
description: Historical visible contract for Starlark policy-engine bakeoff spikes.
---

# Starlark Policy Engine Spike Contract

This visible contract defines a short architecture spike for programmable
policy evaluation. It is not a full product implementation. The goal is to
compare the cost, safety, traceability, and integration shape of four variants:

- Go with native Starlark
- Rust with native Starlark
- Elixir with a Rust or Go Starlark sidecar
- Elixir with a Rustler NIF wrapping Rust Starlark

Use a 30 minute default agent implementation timebox. Complete deterministic
policy execution and fail-closed behavior first; AST/source-span visualization
metadata is a differentiator after the core evaluator works.

## Policy ABI

Expose a prototype-only endpoint or callable test surface that evaluates a
Starlark policy against this input shape:

```json
{
  "request": {
    "model": "ingary/coding-balanced",
    "estimated_tokens": 1200,
    "metadata": {"tenant": "example", "session": "s1"}
  },
  "history": [
    {"kind": "request", "text": "hello", "session": "s1"},
    {"kind": "response", "text": "shell rm -rf example", "session": "s1"}
  ],
  "structured_output": {
    "final_status": "completed_after_guard",
    "guard_events": [
      {"rule_id": "structured-json", "guard_type": "json_syntax"}
    ]
  }
}
```

The evaluator returns:

```json
{
  "action": "allow",
  "model": null,
  "reason": "policy allowed request",
  "trace": [
    {"rule": "default", "result": true, "span": "policy.star:1:1-1:10"}
  ]
}
```

Allowed actions:

- `allow`
- `retry`
- `block`
- `switch_model`

Errors, timeouts, unsupported imports, or sandbox violations must fail closed
with `action = "block"` and a receipt/trace reason.

## Required Policies

Native tests should cover these policy examples:

1. **Allow By Default**
   A simple policy returns `allow` for an ordinary request.

2. **Regex Count In Session History**
   Count recent current-session history entries matching a regex/literal such
   as `rm -rf`. If the count is at or above a threshold, return `block`.

3. **Structured Guard Retry**
   If structured-output guard events include `json_syntax`, return `retry` with
   a reason that mentions structured validation.

4. **Dynamic Model Switch**
   If `estimated_tokens` exceeds a threshold, return `switch_model` with a
   configured larger model.

5. **Fail Closed On Error**
   A policy that raises an exception must return `block` and include error
   evidence without leaking host internals.

6. **Runaway Policy Timeout/Fuel**
   An infinite loop or intentionally expensive loop must be stopped by timeout,
   fuel, or instruction limit and return `block`.

7. **Sandbox Boundary**
   Imports or filesystem/network access attempts must be unavailable and must
   fail closed.

## Trace And Visualization Expectations

Core traces must include at least:

- policy name or rule id
- action selected
- boolean or enum result
- reason

Advanced traces should include:

- source file and line/column span where practical
- branch/function names used in the decision
- enough data to highlight the branch that fired in a future UI

If source spans are not practical in the timebox, record that limitation and
return stable rule identifiers instead.

## Variant-Specific Notes

Go native should use the Go Starlark implementation if available.

Rust native should use a Rust Starlark runtime/parser if available.

Elixir sidecar should prefer a supervised local child process boundary over a
global singleton. Stdio, loopback HTTP, or Unix domain sockets are acceptable
for the spike if the result documents the tradeoff.

Elixir Rustler should use dirty schedulers or another safe strategy for
potentially blocking policy execution. If a safe NIF cannot be finished inside
the timebox, document the blocker and avoid unsafe long-running BEAM scheduler
work.

## Done Criteria

- Native tests cover the required policies.
- The implementation has a deterministic test config or endpoint.
- The evaluator blocks on errors and runaway policies.
- The result artifact records checks, latency notes, safety risks, dependency
  choices, and adversarial review findings.
- The result artifact clearly states whether Starlark is viable for this
  backend shape.
