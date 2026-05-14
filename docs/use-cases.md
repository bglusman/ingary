---
layout: default
title: Ingary Use Cases
description: Candidate Ingary policy examples grounded in agentic workflow failure modes.
---

# Use Cases

These examples are working hypotheses for Ingary's first policy library and
test suite. They are intentionally focused on constrained agentic workflows
where the operator knows what failure looks like.

<div class="notice">
  <strong>Status:</strong> these are not finished product claims. They are
  candidate scenarios for docs-driven development: each one should become a
  reproducible test, a receipt shape, and eventually a UI view.
</div>

## Evidence Themes

Public production-agent writeups repeatedly point at the same pain points:
retry loops and tool spam, malformed structured output, weak traceability,
unclear handoff points, and hard-to-debug failures that look successful at the
end of the run.

Useful references:

- [Agent Patterns: Why AI Agents Fail](https://www.agentpatterns.tech/en/failures/why-agents-fail)
- [Latitude: Detecting AI Agent Failure Modes in Production](https://latitude.so/blog/ai-agent-failure-detection-guide)
- [Amazon Bedrock: structured output](https://docs.aws.amazon.com/bedrock/latest/userguide/structured-output.html)
- [Cohere: structured outputs](https://docs.cohere.com/v2/docs/structured-outputs)
- [Trace-driven debugging for AI agent failures](https://zylos.ai/research/2026-04-30-trace-driven-debugging-ai-agent-failures)

## Candidate Policy Examples

### Ambiguous Success

An agent says the job is done, but the expected artifact, ticket update,
database record, or customer-visible output is missing.

Ingary policy:

- match request or model output for completion language
- check for required artifact metadata or structured output fields
- alert an operator if the claim and artifact state disagree
- record the mismatch in the receipt

Falsifiable value:

- fewer silent-success incidents
- faster operator diagnosis
- clearer regression tests for "done means done"

### Tool Loop Or Tool Spam

The agent repeats the same tool or provider request without meaningful state
change, often consuming budget while appearing active.

Ingary policy:

- track repeated calls, retries, or similar prompt fragments by session/run
- inject a reminder, reroute to a more capable model, or escalate after a
  configured threshold
- record the threshold crossing and decision path in receipts

Falsifiable value:

- lower runaway token/tool spend
- fewer hung agent sessions
- earlier human handoff

### Structured Output Boundary

Downstream systems expect JSON, XML, or another machine-readable contract, but
the model returns malformed or semantically incomplete output.

Ingary policy:

- require a structured-output mode for the synthetic model
- validate before the consumer sees the output
- retry with validation feedback or fail closed
- record the validation failure class and repair count

Falsifiable value:

- fewer parser failures downstream
- lower retry volume after prompt or model changes
- visible distinction between invalid syntax and invalid semantics

### Context And Cost Budget

A workflow gradually grows context until smaller models fail, latency increases,
or expensive fallbacks become the default.

Ingary policy:

- route by estimated prompt tokens and configured context windows
- alert when the route crosses a cost or latency threshold
- record skipped models and route reasons in receipts

Falsifiable value:

- measurable provider-cost changes
- lower p95 latency for constrained tasks
- clearer model-selection decisions

### Prompt Experiment Guardrails

Operators want to test prompt preambles, postscripts, or model variants without
turning every agent integration into a bespoke experiment.

Ingary policy:

- version prompt transforms with the synthetic model
- apply transforms consistently across clients
- record which transform version influenced a run
- compare receipt outcomes across variants

Falsifiable value:

- safer prompt iteration
- less duplicated prompt logic in agent code
- easier rollback when a prompt change regresses behavior
