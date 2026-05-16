---
layout: default
title: Wardwright Use Cases
description: Candidate Wardwright policy examples grounded in agentic workflow failure modes.
---

# Use Cases

These examples are working hypotheses for Wardwright's first policy library and
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
- [LangGraph interrupts for human-in-the-loop approval](https://docs.langchain.com/oss/python/langgraph/human-in-the-loop)
- [oh-my-pi Time Traveling Streamed Rules](https://github.com/can1357/oh-my-pi#-time-traveling-streamed-rules-ttsr)

## Escalation Vocabulary

Wardwright should use two different terms:

- **alert**: asynchronous notification. Wardwright records a receipt event and
  sends a sink notification, such as webhook, Slack, Telegram, email, or UI
  inbox. The original request keeps following the configured policy action:
  allow, retry, reroute, block, or fail. The alert does not wait for a human
  reply.
- **approval gate**: synchronous or resumable human review. Wardwright pauses the
  request lifecycle, persists enough state to resume, waits for an explicit
  approve/edit/reject decision, and has timeout semantics. This is a different
  product surface from alerting and is not part of the current mock backend.

Where this document says "human escalation" for MVP examples, read it as
**asynchronous alerting** unless the action is explicitly named
`require_human_approval`.

## Candidate Policy Examples

### Ambiguous Success

An agent says the job is done, but the expected artifact, ticket update,
database record, or customer-visible output is missing.

Wardwright policy:

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

Wardwright policy:

- track repeated calls, retries, or similar prompt fragments by session/run
- normalize the tool namespace, tool name, phase, risk class, and redacted
  argument/result hashes before policy code evaluates the loop
- inject a reminder, reroute to a more capable model, or alert after a
  configured threshold
- record the threshold crossing and decision path in receipts

Falsifiable value:

- lower runaway token/tool spend
- fewer hung agent sessions
- earlier operator visibility

### Tool-Specific Model Policy

The same public synthetic model may need different governance depending on the
tool context. A call preparing arguments for a write-capable ticket, shell,
GitHub, or database tool should not necessarily use the same route and policy
bundle as a call summarizing a read-only browser result.

Wardwright policy:

- classify model calls by normalized tool context, not provider-specific tool
  payloads
- attach policy bundles or route constraints by tool namespace, phase, and risk
  class
- record selector match/miss evidence in receipts and simulations
- keep raw tool arguments and results out of receipts unless explicit redacted
  capture is enabled

Falsifiable value:

- the same `model` ID behaves differently for read-only and write-capable tool
  contexts
- reviewers can see why a stricter policy bundle was attached
- cross-session reports can group failures by tool family without exposing raw
  tool payloads

### Structured Output Boundary

Downstream systems expect JSON, XML, or another machine-readable contract, but
the model returns malformed or semantically incomplete output.

Wardwright policy:

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

Wardwright policy:

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

Wardwright policy:

- version prompt transforms with the synthetic model
- apply transforms consistently across clients
- record which transform version influenced a run
- compare receipt outcomes across variants

Falsifiable value:

- safer prompt iteration
- less duplicated prompt logic in agent code
- easier rollback when a prompt change regresses behavior

## Spike Candidates

These are concrete experiments that can become examples, BDD scenarios, and
property generators.

| Direction | Value hypothesis | Data needed | First test |
|---|---|---|---|
| JSON/XML repair gate | Reduces downstream parser and semantic-contract failures. | Output buffer, schema/parser errors, retry count. | Generate malformed and semantically incomplete outputs; assert retry or block before release. |
| Tool-context policy selector | Lets one public model use different policies for different tool intents. | Normalized tool namespace/name/phase/risk, selector id, route constraints, redacted hashes. | Send two requests to the same model with different tool contexts; assert different policy bundles and receipt evidence. |
| Session tool-loop detector | Reduces repeated tool/provider calls that spend tokens without changing state. | Session-scoped tool name, args hash, result hash, status. | Generate repeated identical tool facts; assert alert/inject/reroute at threshold. |
| TTSR deprecated-pattern guard | Saves context until a rule matters while preventing known bad output from reaching consumers. | Stream ring buffer, trigger offset, one-shot rule state. | Generate streams with trigger split across chunks; assert trigger before release. |
| Async operator alert sink | Improves visibility without claiming synchronous human approval. | Receipt event, sink status, delivery attempt metadata. | Trip a policy; assert receipt event and sink delivery record even if sink fails. |
| Approval gate | Enables true human review for irreversible actions, but requires persistence and timeout semantics. | Pending request state, approval token, deadline, resume decision. | Simulate approve/reject/edit with timeout and idempotent resume. |
| Prompt experiment receipts | Makes Wardwright useful as a prompt experiment boundary. | Prompt transform version, route, outcome labels, latency/cost. | Run A/B variants over fixture tasks; assert receipts can group by transform version. |
| Cost/context budget guard | Prevents silent migration from cheap/fast routes to expensive/slow routes. | Estimated tokens, route selection, rolling run/session/tenant budget. | Generate calls near budget/context thresholds; assert route/degrade/alert decisions. |
| Trace-to-regression loop | Turns production incidents into durable examples. | Receipt timeline, policy events, failure label, expected future behavior. | Import a labeled receipt; generate a BDD fixture that fails before the policy is added. |

## Policy Engine Implications

These examples need different data scopes. Structured output can run on the
current attempt. Tool-loop detection needs recent events from the same run or
session. DOS controls eventually need tenant/user-level windows. Wardwright should
therefore make policy state explicit and bounded instead of giving policy code
arbitrary access to receipts or storage.

See [Policy Engine MVP](policy-engine.html) for the proposed initial phases,
state scopes, and action model.
