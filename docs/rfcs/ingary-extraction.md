---
layout: default
title: Ingary Extraction
---

# RFC: Ingary Extraction

Status: Draft for critique

Project name: Ingary

## Purpose

Extract Calciforge's synthetic model idea into a standalone product and
library named Ingary. Calciforge should become the first consumer, but Ingary must
stand on its own as a lighter, less Calciforge-opinionated model control plane
with an OpenAI-compatible HTTP API, a Rust API, provider-adapter boundaries,
stream governance, receipts, and a UI for understanding and editing model
behavior.

The product should not present itself as another generic LLM gateway. That
market already has credible projects and hosted products. The differentiated
claim is:

> Stable synthetic model contracts with explainable routing, bounded streaming
> governance, and receipts for every routing and stream-policy decision.

## Latest Calciforge Context Reviewed

This draft was written after fetching remote refs on 2026-05-13. The local
checkout was on a stale feature branch, so architecture assumptions were taken
from `origin/main`, not only from the current working tree.

Relevant recent `origin/main` changes:

- `#204` generalized OpenAI-compatible provider adapters. `helicone`,
  `litellm`, `portkey`, `tensorzero`, `future-agi`, `openrouter`, and plain
  `http` now share the same request path with engine policy overlays.
- `#202` added Helicone streaming chat response handling and boundary
  aggression tests.
- `#205` added shared proxy telemetry sinks.
- `docs/adr/0002-provider-adapter-boundary.md` accepted the provider-adapter
  boundary as the durable Calciforge model-call abstraction.
- Open PRs at review time were channel/E2EE focused, not model-gateway
  focused: `#177` Matrix E2EE prototype and `#178` Twilio channel experiment.

Extraction implication: the new product should probably own the generalized
provider-adapter boundary, not just the current alloy/cascade/dispatcher route
planner. Calciforge can then consume it either through the Rust API or through
the standalone OpenAI-compatible HTTP boundary once the product matures.

## Product Thesis

Application and agent teams should not hardcode provider model IDs forever.
They should call stable names such as:

- `coding-balanced`
- `local-first-private`
- `long-context-safe`
- `json-extractor-cheap`
- `premium-review`

The synthetic model owns the evolving behavior behind that name:

- route graph
- provider selection
- context-window fit checks
- fallback policy
- stream policy
- retry/escalation behavior
- receipts
- eval history
- rollout state

This is valuable only if the product makes hidden model decisions auditable and
testable. Without receipts, simulation, and versioning, it collapses into a
generic gateway feature.

## Primary Users

### Strong Fits

- AI platform teams that want one model contract per workload rather than
  model-choice logic duplicated in application code.
- Coding-agent operators balancing local models, subscription gateways, and
  premium models.
- Internal agent platforms that need sticky session behavior, route receipts,
  and controlled escalation.
- Privacy-sensitive teams that want local-first routing with explicit cloud
  escalation.
- High-volume extraction/classification/summarization teams where cost,
  latency, and failure behavior are operational concerns.

### Weak Fits

- Simple chatbots with one provider and low traffic.
- Teams that already delegate all model policy to a hosted gateway and do not
  need explainability or route versioning.
- One-off scripts where model selection is not an operational surface.

## Market Critique

Existing gateways already cover important pieces:

- LiteLLM: unified provider access, proxy, virtual keys, budgets, retries,
  fallbacks, load balancing.
- Portkey: gateway configs, conditional routing, fallbacks, load balancing,
  metadata-based decisions.
- Helicone: gateway routing, observability, provider routing, dashboards.
- OpenRouter: hosted model marketplace and provider routing.
- Vercel AI Gateway and Cloudflare AI Gateway: app-developer friendly gateway
  surfaces with model fallback and observability.
- Kong AI Gateway: enterprise API-gateway posture for AI traffic.
- RouteLLM, Not Diamond, and Unify: intelligent model choice and cost/quality
  routing.

Therefore the product should not compete on "we route and retry." It should
compete on these sharper capabilities:

- synthetic models as versioned contracts
- route graph simulation before rollout
- context-window-safe dispatch
- stream governance before consumers see output
- state-machine receipts for routing and stream triggers
- agent-session stickiness and controlled escalation
- UI that explains model behavior, not only provider metrics

## Non-Goals For The First Product

- Full Calciforge extraction.
- Channel routing.
- Secret substitution.
- Host-agent operations.
- General web/MITM security proxy behavior.
- Provider marketplace billing.
- Fine-tuning or model hosting.
- Prompt management as a primary product category.
- Silent, arbitrary output rewriting as a default behavior.

## Core Concepts

### Synthetic Model

A stable public model ID that resolves to a route graph and stream policy.

### Route Graph

A typed graph that selects one or more concrete attempts.

Initial node types:

- `alias`: stable name pointing to another graph node or model.
- `dispatcher`: choose by request shape, starting with smallest context window
  that fits.
- `cascade`: ordered fallback chain.
- `alloy`: weighted or round-robin among interchangeable targets.
- `guard`: policy gate for tenant, model capability, data class, budget, or
  region.
- `concrete_model`: terminal model served by a provider adapter.

### Stream Policy

A bounded policy layer that observes normalized provider stream events before
the consumer receives them.

Policy actions:

- `allow`
- `hold`
- `redact`
- `abort_retry`
- `inject_reminder_and_retry`
- `escalate`
- `block_final`
- `mark_receipt`

`rewrite` may be supported later for narrow transforms, but the safer first
class behavior is abort/retry/escalate before release.

### Receipt

A structured, durable record of what the synthetic model did and why.

Receipts must include:

- requested synthetic model
- exact immutable route version
- consuming application, agent, user, tenant, and session/run identifiers when
  supplied by the caller
- request classification
- selected target
- skipped targets and reasons
- attempts and failure classes
- stream-policy triggers
- whether violating output was released
- latency, token, and cost data when available
- final status

## Architecture

```text
          clients / agents / Calciforge
                    |
                    v
        OpenAI-compatible HTTP boundary
                    |
                    v
        auth / caller / request context
                    |
                    v
        synthetic route planner
                    |
                    v
       provider adapter execution layer
                    |
                    v
        normalized provider stream/events
                    |
                    v
        bounded stream policy governor
                    |
                    v
          consumer stream / response

       every stage emits receipt events
```

### Package Layout

Proposed Rust workspace:

```text
ingary/
  crates/
    ingary-core/           # route graph, validation, planner, receipts
    ingary-policy/         # declarative policy + bounded policy VM
    ingary-stream/         # stream event normalization and ring buffers
    ingary-adapters/       # provider adapter traits and built-in adapters
    ingary-gateway/        # HTTP server, auth, persistence, OpenAI compat
    ingary-ui/             # web UI app
    ingary-cli/            # config validation, simulation, local admin
```

Names are placeholders. If the product name does not abbreviate cleanly, use
clear crate names rather than forcing an acronym.

### Rust API

The Rust API should be embeddable by Calciforge or any other Rust host.

Minimum API shape:

```rust
let registry = SyntheticModelRegistry::from_config(config)?;
let request = ModelRequest::from_openai_chat(chat_request)?;
let plan = registry.plan("coding-balanced", &request, RequestContext::default())?;
let result = executor.execute(plan, request).await?;
```

Core traits:

- `RoutePlanner`
- `TokenEstimator`
- `ProviderAdapter`
- `StreamNormalizer`
- `StreamPolicy`
- `ReceiptSink`
- `SessionAffinityStore`

`RequestContext` is a first-class API type, not an unstructured metadata bag.
It should carry stable caller dimensions used for policy, receipts, UI
filtering, and logs:

- `tenant_id`
- `application_id`
- `consuming_agent_id`
- `consuming_user_id`
- `session_id`
- `run_id`
- request tags

HTTP callers should be able to provide these dimensions through explicit
headers and/or request metadata. The gateway should also preserve a stable
anonymous caller ID when the deployment cannot or should not know the human
user.

Calciforge integration can start by using `ingary-core` and `ingary-adapters`
directly. Later, Calciforge can call the standalone HTTP boundary if that
becomes the cleaner deployment shape.

### HTTP API

The public serving API must be plain HTTP/S and OpenAI-compatible.

Required serving endpoints:

```text
GET  /v1/models
POST /v1/chat/completions
POST /v1/responses
POST /v1/synthetic/simulate
GET  /v1/synthetic/models
GET  /v1/synthetic/models/{id}
GET  /v1/receipts/{id}
GET  /v1/runs/{run_id}/receipts
```

### Caller Traceability

Caller traceability is best effort because there is no universal standard for
agent/user identity in OpenAI-compatible traffic. The product should support
explicit caller dimensions everywhere, but it must record the provenance and
confidence of each field.

Identity source priority:

1. Trusted server-side auth context: API key, mTLS identity, OIDC/JWT claim, or
   deployment-owned reverse proxy header.
2. Product-owned explicit headers, for clients that can set them:
   `X-Ingary-Tenant-Id`, `X-Ingary-Application-Id`, `X-Ingary-Agent-Id`,
   `X-Ingary-User-Id`, `X-Ingary-Session-Id`, `X-Ingary-Run-Id`, and
   `X-Client-Request-Id`.
3. Request-body metadata when the client or SDK supports it.
4. Provider/gateway metadata from an upstream boundary such as LiteLLM team,
   key, project, or user records.
5. Stable anonymous caller derived from the serving credential when no user or
   agent identity is available.

Research notes:

- OpenAI documents `X-Client-Request-Id` as a caller-supplied request trace ID
  for supported endpoints, including chat completions and responses. It is a
  request correlation ID, not a user or agent identity. See
  <https://platform.openai.com/docs/api-reference/chat/create-chat-completion>.
- OpenAI also exposes organization/project headers for usage attribution at the
  provider boundary. Those are not the same as consuming application, agent, or
  end-user identity, but they show that deployment-level attribution already
  exists in common APIs.
- LiteLLM's proxy docs emphasize multi-tenant spend tracking, virtual keys,
  teams, users, auth hooks, logging hooks, and callbacks. A standalone product
  should ingest that metadata when it is upstream or downstream of LiteLLM
  rather than forcing duplicate identity mapping. See
  <https://docs.litellm.ai/>.
- Some agent runtimes will not pass useful identity metadata through
  OpenAI-compatible calls. For those, the product can still group by API key,
  synthetic model, session header, source IP class if enabled, and request ID,
  but it should label those dimensions as inferred or anonymous.

The UI should never imply a consuming-user field is authoritative unless it came
from a trusted source. Receipts should carry both the normalized value and the
source, for example `trusted_auth`, `header`, `body_metadata`, `provider_key`,
or `derived_anonymous`.

Admin/control endpoints:

```text
GET  /admin/providers
POST /admin/providers
GET  /admin/synthetic-models
POST /admin/synthetic-models/{id}/drafts
POST /admin/synthetic-models/{id}/versions/{version}/publish
POST /admin/synthetic-models/{id}/versions/{version}/canary
POST /admin/simulate
GET  /admin/receipts
```

Serving endpoints should work with ordinary OpenAI clients by setting:

```text
base_url = https://gateway.example.invalid/v1
model = coding-balanced
```

### Provider Adapter Boundary

The new product should own the provider-adapter boundary. Calciforge's current
`origin/main` direction already treats the adapter as the durable model-call
abstraction, and that abstraction is useful outside Calciforge.

Provider adapter responsibilities:

- translate public model ID to upstream model ID
- apply configured headers/body extensions
- authenticate to provider boundary
- normalize provider error classes
- normalize streaming events
- report provider metadata and capabilities

Initial adapters:

- OpenAI-compatible HTTP
- LiteLLM-compatible HTTP
- Helicone-compatible HTTP
- OpenRouter-compatible HTTP
- Ollama/vLLM local OpenAI-compatible HTTP
- mock adapter for tests

Later adapters:

- Anthropic native
- Google Gemini native
- model-hosting/runtime library adapters
- provider gateway plugins loaded out of process

Design rule: OpenAI-compatible adapters should share one transport core with
small engine overlays. Do not clone a gateway per provider.

## Deployment Topologies

The product should support multiple positions relative to systems such as
LiteLLM, Helicone, OpenRouter, Portkey, TensorZero, Future AGI, or an internal
gateway. Operators will have different existing investments, and forcing a
single topology would make adoption harder.

### Model Namespace Contract

The public model namespace is part of the product contract.

Definitions:

- **Synthetic model ID**: a stable public model name backed by route logic, for
  example `coding-balanced`.
- **Concrete model ID**: an internal route target backed by a provider adapter,
  for example `local/qwen-coder` or `managed/kimi-k2.6`.
- **Upstream model ID**: the exact model name sent to the downstream provider or
  gateway, for example `qwen-coder`, `openai/gpt-5-mini`, or a LiteLLM model
  group name.

Serving behavior:

- `/v1/models` should list synthetic models by default.
- Admin endpoints may list concrete models and upstream mappings.
- Receipts always include synthetic model, concrete model, provider adapter, and
  upstream model IDs.
- Public clients should not need to know concrete model IDs unless the operator
  intentionally exposes them.

Recommended public names:

```text
coding-balanced
local-first-private
json-extractor-cheap
```

Recommended names when another gateway owns a shared model namespace:

```text
ingary/coding-balanced
ingary/local-first-private
ingary/json-extractor-cheap
```

Non-goal:

- Do not register every concrete model as a separate public provider/model by
  default. That makes Ingary look like a provider catalog and weakens the
  synthetic model abstraction.

### Topology A: Synthetic Platform In Front

```text
client / agent
  -> Ingary
  -> LiteLLM / Helicone / OpenRouter / internal gateway
  -> model provider
```

Use when the synthetic platform owns the public model contract and downstream
gateways own provider registries, virtual keys, provider credentials, or
dashboards.

Advantages:

- Best fit for synthetic model contracts. Clients call `coding-balanced`
  directly.
- Full route and stream-policy receipts at the product boundary.
- The product can decide when to call a managed gateway, local model, or direct
  provider.
- Good Calciforge fit: Calciforge can point at one OpenAI-compatible boundary.

Tradeoffs:

- Must preserve enough downstream metadata for LiteLLM/Helicone dashboards to
  remain useful.
- Downstream gateway may see the synthetic platform as one client unless caller
  metadata is forwarded.
- Provider-specific features hidden behind the downstream gateway may be opaque.

Recommended default for the standalone product.

Model namespace recommendation:

- Public clients should usually see synthetic model IDs directly, such as
  `coding-balanced`, `local-first-private`, or `json-extractor-cheap`.
- Concrete model details stay hidden unless explicitly exposed through admin
  endpoints or receipts.
- Downstream gateways can receive translated model IDs such as
  `managed/kimi-k2.6`, `openrouter/anthropic/claude-sonnet`, or whatever the
  provider adapter requires.

### Topology B: Synthetic Platform Behind

```text
client / agent
  -> LiteLLM / Helicone / enterprise gateway
  -> Ingary
  -> model provider or local runtime
```

Use when an organization already requires every LLM request to enter through an
enterprise gateway for auth, billing, SSO, audit, or network policy.

Advantages:

- Fits organizations that already standardized on a gateway.
- Existing auth, virtual keys, budgets, and gateway dashboards stay in front.
- The synthetic platform can be adopted as one managed provider/route.

Tradeoffs:

- The front gateway may hide the original caller unless it forwards metadata.
- Stream governance can still protect downstream consumers, but receipts may
  have weaker user/agent attribution.
- Front-gateway retries or transformations may interfere with synthetic route
  receipts unless disabled or coordinated.

This topology should be supported, but docs should warn that caller
traceability depends on forwarded headers/metadata.

Compatibility note:

- This works best with front gateways that can register arbitrary
  OpenAI-compatible backends or custom providers. LiteLLM is a strong fit for
  this shape. Portkey-style custom host/provider integrations may also work.
  Hosted gateways that expose only their own provider catalog may be better as
  downstream provider adapters than as front gateways.

Model namespace recommendation:

- The front gateway should register the synthetic platform as one
  OpenAI-compatible backend/provider.
- Prefer a prefixed namespace such as `ingary/coding-balanced` or
  `synthetic/coding-balanced` when the front gateway's model namespace is
  shared with other providers.
- A flat model name such as `coding-balanced` is acceptable when the operator
  controls the whole gateway namespace and there is no collision risk.
- Avoid registering every concrete downstream model as a separate front-gateway
  provider unless the operator intentionally wants to expose implementation
  details. The main product value is that synthetic models hide those details
  behind a stable contract.

### Topology C: Sidecar / Embedded Library

```text
application / Calciforge
  -> embedded route planner + stream governor
  -> provider adapter / gateway
```

Use when a host application wants synthetic routing without operating another
HTTP service.

Advantages:

- Lowest deployment overhead.
- Strong local integration with host identity and sessions.
- Good first Calciforge extraction path.

Tradeoffs:

- The standalone UI needs a receipt sink or control-plane bridge.
- Every host language needs bindings or an HTTP fallback.
- Operational behavior may drift if hosts embed different library versions.

### Topology D: Standalone Direct Gateway

```text
client / agent
  -> Ingary
  -> model provider / local runtime
```

Use for small deployments, local development, and teams that do not already
operate a gateway.

Advantages:

- Simplest mental model.
- Best end-to-end receipts.
- No dependency on another gateway's metadata conventions.

Tradeoffs:

- The product must own more provider-adapter and credential behavior.
- It competes more directly with existing gateway products.

### Topology Guidance

The product should make topology an operator decision, but the docs should be
opinionated:

- Default recommendation: run the synthetic platform in front of managed
  gateways when synthetic model behavior is the primary contract.
- Enterprise recommendation: support running behind the organization's required
  gateway, but require metadata forwarding for useful caller traceability.
- Namespace recommendation: expose synthetic models as the public unit. Use a
  prefix such as `ingary/` only when another gateway owns a larger shared model
  namespace.
- Embedded recommendation: use the Rust API for Calciforge and other close
  integrations until the standalone gateway and UI are mature.
- Direct recommendation: use standalone direct mode for local/small deployments
  and tests, not as the only product story.

## Stream Governance

### Stream Event Model

Provider streams should normalize into internal events:

```text
Start
TextDelta(choice, text)
ReasoningDelta(choice, text)
ToolCallStart(choice, index, id, name)
ToolCallArgumentsDelta(choice, index, text)
ToolCallEnd(choice, index)
UsageDelta(...)
Finish(choice, reason)
Error(...)
```

The stream governor operates on these events, not raw bytes, whenever possible.

### Buffering Modes

```text
pass_through
  Lowest latency. Can stop future output but cannot guarantee violating output
  never reached the consumer.

buffered_horizon
  Hold the last N chars/tokens/events. Release content only after it leaves the
  protected window without triggering policy.

semantic_boundary
  Hold until a complete sentence, paragraph, JSON value, code block, or tool
  call boundary.

full_buffer
  Hold the full response until completion. Safest; not truly streaming.
```

Default recommendation:

- agent/tool-call traffic: `semantic_boundary`
- human chat: `buffered_horizon`
- structured extraction: `full_buffer`

### State Machine

Stream policy should be bounded by a state machine:

```text
observing -> triggered -> retrying -> observing
observing -> triggered -> escalating -> observing
observing -> triggered -> blocked
observing -> completed
```

Each state transition must produce a receipt event.

Limits:

- max buffered chars/tokens/events
- max policy CPU per event
- max policy CPU per request
- max rule triggers
- max retries
- max escalations
- max synthetic branch switches
- max receipt event size

### Declarative Rules

Most users should not need programmable policy.

Example:

```toml
[[stream_rules]]
id = "no-deprecated-client"
event = "text_delta"
match.regex = "OldClient\\("
window_tokens = 256
action = "inject_reminder_and_retry"
reminder = "Do not use OldClient. Use NewClient instead."
max_triggers_per_request = 1
```

### Programmable Policy Rules

The policy language is an implementation detail. The product requirement is a
bounded, deterministic policy VM that can react to request metadata, route
state, and normalized stream events. Starlark is a strong candidate because
there are mature Rust and Go implementations and Calciforge already has
Starlark policy experience, but it should not be baked into the product
contract. Elixir or other implementations may choose a different embedded DSL,
call a sandboxed sidecar, or bind to a Rust policy engine.

Programmable rules should be an advanced extension, not the only policy
interface.

The portable contract should define an engine-neutral policy ABI first:

- inputs: caller context, request metadata, route graph state, selected target,
  buffered stream window, provider event, attempt history
- outputs: pass, transform request, annotate receipt, retry with reminder,
  reroute, escalate, block final output
- constraints: deterministic execution, bounded CPU/reductions, bounded memory,
  no ambient filesystem/network/process access, explicit state handoff

Starlark should be the first portable advanced policy language because model
artifacts may outlive any one backend prototype. Keeping the policy code as
data means the same synthetic model can run under Rust, Go, or Elixir, produce
comparable receipts, and participate in the same artifact hub. The product
contract still exposes a policy-engine ABI, not a promise that Starlark is the
only possible implementation.

Initial policy engine direction:

- `builtin`: declarative engine for common transforms, regex/literal guards,
  JSON/XML/protobuf-JSON validation, and bounded repair/retry actions.
- `starlark`: first readable portable programmable engine. Rust can use a
  native Starlark engine, Go can use the Go Starlark implementation, and Elixir
  should prefer a shared sidecar first. A Rustler wrapper around a Rust
  Starlark engine is a valid later optimization for trusted deployments, but it
  is not as clean an isolation boundary as a sidecar.
- `wasm`: later optional engine target for stronger isolation and packaged
  extensions. WASM should be treated as an execution format, not the default
  authoring language. If shipped, it should sit behind the same ABI used by
  Starlark and the built-in declarative engine.
- `external`: bring-your-own policy engine over a local API/sidecar contract for
  operators who need a different language or isolation model.
- `gleam_core`: typed BEAM business logic behind Elixir operational boundaries.
  Gleam is not primarily a sandbox language; it is a candidate for making policy
  contracts, route decisions, cache facts, guard-loop results, and receipt
  classifications harder to express incorrectly. Elixir should still own HTTP,
  supervision, runtime registries, dynamic model/session processes, and
  integration glue unless a spike proves Gleam can simplify those surfaces too.

Dune is a plausible Elixir candidate for local/operator-authored policy because
it supports allowlisted modules/functions, isolated process execution,
configurable timeout/reduction/memory limits, stdout capture, and atom-leak
avoidance. It should be treated as a best-effort sandbox for trusted/local
policy experiments, not the portable artifact language and not a strong hostile
multi-tenant security boundary.

Untrusted third-party policy should run through a sidecar, WASM runtime, or
hosted policy service with explicit trust/provenance metadata. The same
synthetic model manifest should declare which engines it requires and whether a
policy is inspectable, opaque remote, or packaged binary.

Declarative policy should cover common cases before programmable policy is
required:

- preamble/postscript prompt transforms
- regex/literal stream guards
- JSON object and JSON Schema validation
- XML well-formedness validation
- protobuf-JSON shape validation
- bounded repair/retry with receipt annotations

For the Elixir/Gleam path, runtime fault isolation should be a first-class
architecture primitive rather than an implementation detail. Synthetic models
should be represented by dynamically supervised model runtimes, and active
caller/session/run state should live under dynamically supervised session
runtimes below the owning model. A failure in one session's cache, stream
window, retry loop, Starlark sidecar, or Rustler dirty NIF evaluation should be
observable in receipts and should not crash unrelated sessions or other model
runtimes. Dirty NIFs should be treated as scheduler-isolation tools, while
sidecars/process boundaries remain the stronger killability and hard fault
containment option. Sidecars are not free: each sidecar boundary should be
evaluated for queueing, cold-start latency, restart storms, protocol failures,
pool sizing, and whether saturation in one model/session failure domain can
apply backpressure to unrelated runtimes.

### Policy Demonstration Hypotheses

Ingary should not be positioned as primarily a security product. Security is one
useful demonstration category, especially because failure cost is easy to
understand, but the broader thesis is that agentic workflows need a separate
point of control, experimentation, and visibility around otherwise hard-to-
predict model behavior.

The strongest early demos should use constrained domains with known failure
modes. Each demo should be falsifiable: the policy either reduces failure
frequency, reduces failure cost, or improves failure visibility in receipts and
operator alerts.

Candidate demos:

1. **Loop and tool-spam governor**
   - Domain: support/refund agent, browser agent, coding agent.
   - Failure: repeated calls to the same tool with equivalent arguments or
     equivalent result hashes.
   - Ingary action: alert operator, inject a "change tactic" reminder, switch to
     a stronger model, or stop with a receipt explaining repeated state.
   - Test signal: same tool/result pair seen N times within a run.

2. **Ambiguous-success governor**
   - Domain: booking, billing, task execution, CI repair.
   - Failure: agent treats partial or empty success as complete.
   - Ingary action: require structured evidence fields before final answer;
     alert if final answer lacks required observations.
   - Test signal: final answer says done while required receipt fields or tool
     evidence are absent.

3. **Structured-output repair governor**
   - Domain: extraction, CRM update, ticket triage, workflow automation.
   - Failure: malformed JSON/XML/protobuf-JSON or semantically invalid fields.
   - Ingary action: buffer output, validate, retry with schema-specific repair
     prompt, block after max attempts, record validation errors.
   - Test signal: invalid output never reaches consumer in enforced mode.

4. **Escalation-on-uncertainty governor**
   - Domain: medical intake, legal intake, financial customer support, internal
     approvals.
   - Failure: confident answer despite missing evidence or low confidence.
   - Ingary action: page/handoff to human, downgrade to draft answer, or ask for
     missing fields.
   - Test signal: answer contains uncertainty markers, missing required facts,
     or contradictory extracted fields.

5. **Cost and context budget governor**
   - Domain: coding agents, research agents, long-running analysis jobs.
   - Failure: context saturation, repeated retries, or runaway token spend.
   - Ingary action: summarize-and-continue, switch model, require operator
     approval, or stop before budget explosion.
   - Test signal: token/tool-call thresholds crossed with no new evidence.

6. **Prompt-management experiment governor**
   - Domain: constrained customer-support or extraction workflows.
   - Failure: one prompt variant works for common cases but fails tail cases.
   - Ingary action: versioned preamble/postscript, canary prompt variants,
     receipt-level comparison by user/agent/session segment.
   - Test signal: policy receipts show prompt variant, route, structured
     validation result, and downstream outcome.

7. **Security guard as example, not identity**
   - Domain: coding agents, data agents, internal tools.
   - Failure: prompt injection, credential leakage, hidden prompt extraction,
     unsafe tool instructions.
   - Ingary action: block, rewrite, route to human review, or annotate receipt.
   - Test signal: known injection/leak markers are caught on input and output.

Human alerting should be a first-class policy action:

```text
policy condition -> receipt event -> alert sink -> operator link to trace
```

Alerts may be emitted in addition to, or instead of, changing model behavior.
This is important because some policies are observability hypotheses before they
are enforcement rules.

Conceptual shape:

```python
def on_event(ctx, event):
    if event.kind == "text_delta" and regex_match(ctx.window.text, r"OldClient\("):
        return retry(
            reason = "deprecated_client",
            reminder = "Do not use OldClient. Use NewClient instead.",
        )

    if event.kind == "tool_call_end" and event.name == "shell":
        if regex_match(event.arguments, r"\bcurl\b"):
            return escalate(reason = "network_tool_call")

    return allow()
```

The policy host API should expose:

- `regex_match`
- `json_path`
- `len`
- request metadata
- route metadata
- bounded stream window
- prior trigger list
- safe action constructors

It should not expose:

- filesystem
- network
- wall-clock mutation beyond provided timestamps
- arbitrary process execution
- secrets

### Code-First Visualization Spike

Starlark policy may still be product-grade if Ingary treats visualization as an
AST plus trace problem rather than a static-proof problem. Typical policies are
expected to be small, so a simple visual projection can carry a lot of value:

- parse functions, branches, comparisons, calls, and return/action constructors
- classify host API calls as detectors, cache reads, route mutations, stream
  actions, final-output actions, or unknown effects
- preserve source spans so the UI can highlight the exact code that produced a
  decision
- run the same generated scenarios used by structured policies
- overlay traces on the AST graph: branch taken, cache count observed, regex
  matched, model switched, stream aborted, retry requested, output blocked
- show scenario diffs between policy versions and pin counterexamples as
  regression fixtures

Parser choices should follow the spike goal:

- Go `go.starlark.net/syntax` is likely the fastest AST projection prototype.
- Rust `starlark` / `starlark_syntax` is the likely runtime-aligned parser if
  Rust becomes authoritative.
- `tree-sitter-starlark` is useful for source-aware editor visualization and
  incremental parsing.
- Python `ast` is acceptable for an early Starlark-like subset prototype if the
  spike explicitly rejects unsupported Python nodes and validates activation
  with a real Starlark parser later.

This spike should be compared against the structured-primitives workbench using
the same policies and scenarios: TTSR, recent-history count/comparison rules,
and dynamic model switching. The win condition is not maximum expressiveness;
it is whether technical policy authors can predict, trust, review, and debug
behavior faster.

## Receipts

Receipt schema should be stable and versioned.

Example:

```json
{
  "receipt_schema": "v1",
  "receipt_id": "example-receipt-id",
  "run_id": "example-run-id",
  "synthetic_model": "coding-balanced",
  "synthetic_version": "2026-05-13.1",
  "caller": {
    "tenant_id": { "value": "example-tenant", "source": "trusted_auth" },
    "application_id": { "value": "calciforge", "source": "header" },
    "consuming_agent_id": { "value": "repo-coder", "source": "header" },
    "consuming_user_id": { "value": "user-42", "source": "body_metadata" },
    "session_id": { "value": "agent-session-7", "source": "header" },
    "tags": ["interactive", "coding"]
  },
  "request": {
    "estimated_input_tokens": 18420,
    "stream": true,
    "tools_present": true
  },
  "decision": {
    "selected": "local/qwen-coder",
    "reason": "smallest_eligible_context_window",
    "skipped": [
      {
        "target": "cheap/small",
        "reason": "context_window_too_small"
      }
    ],
    "fallbacks": ["kimi/k2.6", "claude/sonnet"]
  },
  "attempts": [
    {
      "model": "local/qwen-coder",
      "status": "aborted_retry",
      "stream_policy": {
        "mode": "buffered_horizon",
        "triggers": [
          {
            "rule": "no-deprecated-client",
            "offset": 1834,
            "action": "inject_reminder_and_retry",
            "released_to_consumer": false
          }
        ]
      }
    },
    {
      "model": "local/qwen-coder",
      "status": "success"
    }
  ],
  "final": {
    "status": "success",
    "latency_ms": 8210
  }
}
```

## Data Model And Storage

Storage is a product decision, not a replaceable implementation detail. Ingary's
main durable objects are versioned control-plane state and high-volume receipt
events. Those two workloads have different shapes and should be modeled
explicitly rather than hidden behind a generic document store.

### Recommendation

Start with a relational event store that supports both SQLite and Postgres
through the same logical schema:

- **SQLite default** for local development, single-user installs, Calciforge
  embedding, demos, and "no external services" deployments.
- **Postgres production path** for team/server deployments, multi-tenant
  installs, retention policies, concurrent writers, backups, and operational
  analytics.
- **Redis optional only** for ephemeral coordination: rate-limit counters,
  short-lived route stickiness, distributed locks, and hot policy/cache state.
  Redis must not be the system of record for receipts or model definitions.
- **DuckDB optional later** for offline analytics over exported receipts,
  benchmarks, and local exploration. It should not be the request-path primary
  store in MVP 1.

The practical bias: design the schema as if Postgres is the serious production
store, but keep the SQL and migration discipline compatible with SQLite for the
local/default product.

### Pluggable Storage Contract

The language/runtime decision and the storage decision should be explored as a
matrix. Each backend prototype should depend on a storage-provider interface,
and each storage implementation should satisfy the same logical behavior
contract. The draft contract lives at
`contracts/storage-provider-contract.md`.

This is plausible if the contract stays at the right level:

- require semantic behavior, not identical physical schemas
- require receipt/query/migration/retention behavior, not a generic ORM
- allow each engine to use its strengths for indexes, JSON, transactions, and
  exports
- run the same storage fixture suite against memory, SQLite, Postgres, and any
  later candidate
- support native adapters for production paths and sidecar adapters for
  cross-language experiments

The matrix should initially look like this:

| Backend | Memory | SQLite | Postgres | Search sink | Event stream | Redis adjunct | DuckDB export |
|---|---:|---:|---:|---:|---:|---:|---:|
| Rust | required | required | candidate | optional | optional | optional | optional |
| Go | required | candidate | candidate | optional | optional | optional | optional |
| Elixir | required | candidate | candidate | optional | optional | optional | optional |

The risk is over-abstraction. If the contract hides too much, Ingary loses the
ability to design good indexes, migrations, and retention jobs. The contract
therefore defines observable behavior and logical entities; each implementation
can choose a schema that fits its database engine.

### Receipts Versus Logs

Receipts and logs overlap but should remain separate product concepts.

Receipts are durable product records that explain synthetic model behavior.
They must be queryable by the UI, tied to model versions, governed by retention
and privacy policy, and stable enough to support simulation, audit, and
debugging.

Logs are operational diagnostics and event streams. They are valuable for
infrastructure observability, incident response, and external audit pipelines,
but a generic log sink is not automatically a receipt store.

The architecture should therefore have two related adapter families:

- storage providers for model definitions, rollout state, receipts, receipt
  events, retention, and UI queries
- event/log sinks for redacted append-only copies of route decisions, stream
  triggers, health events, metrics, and operational diagnostics
- search sinks for derived receipt explorer indexes, faceted search, text search
  over redacted artifacts, and dashboard exploration

The receipt writer can fan out to both surfaces. Durable storage failure is a
product correctness issue and should fail closed or follow explicit degradation
policy. Log-sink failure should usually degrade open with clear backpressure,
queue, or drop policy.

Elasticsearch, OpenSearch, Meilisearch, and Typesense are best considered
search sinks first. Kafka, Redpanda, Iggy, NATS JetStream, and similar systems
are best considered event streams first. Either category can become part of a
storage solution if a materialized/queryable layer satisfies the storage
contract, but neither should be assumed to replace the durable receipt store by
default.

### Why Not Pick One Store Only

SQLite-only is attractive for distribution, but it becomes painful for hosted or
team deployments that need concurrent ingestion, retention jobs, and dashboard
queries across many agents/users.

Postgres-only is operationally strong, but it weakens the "lightweight
dependency" and Calciforge-embedded story.

DuckDB is excellent for analysis, but its strengths are columnar scan and
offline analytics, not serving the live OpenAI-compatible gateway path.

Redis is useful, but making it the durable receipt store would make audit,
backup, query, and retention semantics fragile.

Search engines are useful for exploration and full-text/faceted filtering, but
they usually make a better derived index than authoritative storage for route
versions, rollouts, and exact receipt history.

Event streams are useful for fanout, replay, async indexing, and audit
pipelines, but they need a materialized store for the UI's query and retention
requirements.

Sinks are also part of the correctness story. Property tests should generate an
expected receipt and an expected sink projection for each request. The oracle
should verify durable receipt state, event-stream delivery/order/idempotency,
search-index visibility, redaction consistency, sink lag/health reporting, and
rebuild from durable receipt events. Asynchronous sinks can be eventually
consistent, but tests must bound the wait and surface stale or missing
projections.

### Logical Entities

Control-plane tables:

- `providers`: provider adapter definitions and health metadata.
- `concrete_models`: provider-owned models with capabilities, context windows,
  price hints, data-region constraints, and status.
- `synthetic_models`: stable public model IDs and namespace settings.
- `synthetic_model_versions`: immutable route graph and stream policy versions.
- `synthetic_model_aliases`: optional public aliases and compatibility names.
- `artifact_imports`: shared model artifact provenance, license, source digest,
  provider-role mappings, and review state.
- `rollouts`: active/draft/canary state, percentages, predicates, and rollback
  pointers.

Receipt/event tables:

- `receipts`: one row per live or simulated request with stable identifiers,
  caller dimensions, selected model, final status, latency, and links to the
  exact synthetic model version.
- `receipt_events`: ordered state-machine events for planning, guards,
  attempts, retries, stream triggers, release/hold decisions, and finalization.
- `provider_attempts`: normalized provider call attempts, failure classes,
  token/cost/latency data, and upstream response IDs when available.
- `stream_triggers`: indexed stream-governance triggers with rule ID, action,
  offset/range, release status, and resulting state transition.
- `receipt_artifacts`: optional redacted prompt/completion/tool-call snapshots
  when content capture is explicitly enabled.

This split lets the UI render fast receipt lists from `receipts`, then drill
into the event timeline without forcing every query to parse large JSON blobs.

### JSON Boundaries

Use structured columns for fields that drive filtering, retention, joins, or UI
grouping. Store JSON for versioned payloads that need forward compatibility.

Structured/indexed fields should include:

- tenant ID, application ID, consuming agent ID, consuming user ID, session ID,
  run ID, and client request ID
- source/provenance for each caller identifier
- synthetic model ID and immutable version ID
- route graph root, selected provider, selected concrete model, status,
  simulation/live flag, created timestamp, latency, token counts, and cost
- stream trigger count, policy action, and "released to consumer" flags

JSON fields are appropriate for:

- raw route graph definition on immutable model versions
- normalized request summary
- policy VM trace details
- provider-specific response metadata
- redacted or user-enabled content artifacts

### Migration Discipline

- Every prototype should use a storage interface even if the first
  implementation is in-memory.
- MVP persistence should add SQLite first, with migrations committed in the
  repo and tested from an empty database and from the previous migration.
- Postgres should use the same logical schema, with dialect-specific migrations
  allowed only where justified by indexing or JSON support.
- Receipt schema versions must be explicit and immutable. New receipt fields
  can be additive; changed semantics require a new schema version.
- Model-version rows must be immutable once activated. Rollback creates or
  points to another active version; it does not mutate history.

### Query Requirements

The UI and API must efficiently support:

- filter receipts by tenant, application, consuming agent, consuming user,
  session, run, synthetic model, version, provider, concrete model, final
  status, simulation/live, stream-policy action, and time range
- group receipts by consuming agent and consuming user
- show p50/p95/p99 latency by synthetic model version and provider
- show fallback/escalation frequency by route graph node
- show stream rules that triggered, whether content was released, and what
  transition happened next
- delete or compact expired receipt artifacts without deleting the audit trail
  required to explain a decision

### Retention And Privacy

- Prompt and completion capture is disabled by default.
- Caller traceability metadata must be visible without prompt or completion
  capture.
- Redaction hooks run before persistence when content capture is enabled.
- Retention policy should be independent for receipt metadata, receipt events,
  and optional content artifacts.
- Export paths should support NDJSON/Parquet-compatible shapes so DuckDB or
  external warehouses can analyze history without becoming the request-path
  store.

## Configuration

The product should support file-first and UI-first workflows. UI edits compile
to the same graph representation as config files.

Sketch:

```toml
[[providers]]
id = "local"
kind = "openai-compatible"
base_url = "http://127.0.0.1:11434/v1"
credential_owner = "provider"

[[providers]]
id = "managed"
kind = "litellm"
base_url = "https://gateway.example.invalid/v1"
credential_owner = "provider"
api_key_file = "/etc/example/model-gateway-client-key"

[[concrete_models]]
id = "local/qwen-coder"
provider = "local"
upstream_model = "qwen-coder"
context_window = 32768
capabilities = ["chat", "tools"]

[[concrete_models]]
id = "kimi/k2.6"
provider = "managed"
upstream_model = "kimi/k2.6"
context_window = 262144
capabilities = ["chat", "tools", "long_context"]

[[synthetic_models]]
id = "coding-balanced"
description = "Local-first coding model with cloud escalation."

[synthetic_models.root]
type = "dispatcher"
strategy = "smallest_context_that_fits"

[[synthetic_models.root.targets]]
model = "local/qwen-coder"

[[synthetic_models.root.targets]]
model = "kimi/k2.6"

[[synthetic_models.stream_rules]]
id = "no-deprecated-client"
event = "text_delta"
match.regex = "OldClient\\("
action = "inject_reminder_and_retry"
reminder = "Do not use OldClient. Use NewClient instead."
```

## Shareable Synthetic Model Artifacts

Synthetic model definitions should be portable artifacts, not only local
database rows. This creates a path for examples, team reuse, version control,
and a public or private hub.

Artifact goals:

- Export any synthetic model version as a self-contained manifest.
- Import a manifest into another deployment with provider mapping prompts.
- Support Git-based review and change history.
- Support a community hub for discovery, examples, ratings, discussions, and
  compatibility notes.
- Keep provider credentials, private endpoints, and deployment identifiers out
  of exported artifacts.

Manifest contents:

- synthetic model ID and semantic version
- route graph with abstract provider requirements
- required model capabilities: context window, tools, JSON/schema support,
  multimodal support, locality/privacy tags
- stream policy rules
- policy VM requirements, if programmable rules are used
- recommended eval set references
- example prompts and expected receipt shape
- compatibility metadata: tested engines, tested provider adapters, known
  limitations
- author, license, provenance, signature/checksum

Manifests must not contain:

- API keys or bearer tokens
- private base URLs
- personal domains or deployment-specific identifiers
- captured prompts/completions from real users unless explicitly packaged as a
  scrubbed eval artifact

Example:

```toml
[artifact]
kind = "synthetic-model"
schema_version = "v1"
id = "coding-balanced"
version = "1.0.0"
license = "Apache-2.0"

[[requirements.providers]]
role = "small_local_coder"
capabilities = ["chat", "tools"]
min_context_window = 32768
locality = "local_preferred"

[[requirements.providers]]
role = "long_context_coder"
capabilities = ["chat", "tools", "long_context"]
min_context_window = 200000

[route.root]
type = "dispatcher"
strategy = "smallest_context_that_fits"
targets = ["small_local_coder", "long_context_coder"]
```

Import flow:

1. Validate manifest schema and signature/checksum when present.
2. Show required provider roles and capabilities.
3. Ask the operator to map abstract roles to local concrete models or managed
   gateway model IDs.
4. Run route simulation and optional evals before activation.
5. Import as a draft version, never directly as active production config.

Hub requirements:

- Public and private registries.
- Search by use case, capabilities, topology, provider assumptions, and stream
  policy features.
- Compatibility matrix per artifact.
- Trust signals: verified publisher, signed artifact, reproducible tests,
  community reports.
- One-click import into draft mode.
- Diff viewer for artifact updates.
- Clear warnings when an artifact requires programmable policy execution.

This should remain optional. Local file-based artifacts and private Git repos
must work without a hosted hub.

## UI Plan

The UI should be low-friction and operational. It should feel like a control
surface for model behavior, not a marketing dashboard.

### Information Architecture

```text
Models
Providers
Receipts
Runs
Simulator
Evals
Policies
Settings
Hub
```

### Wireframe: Model Catalog

```text
+--------------------------------------------------------------------------------+
| Synthetic Models                                             [New model] [Sim] |
+--------------------------------------------------------------------------------+
| Filter: [all models...] Agent [all v] User [all v] Status [active v] Sort [...]|
+--------------------------------------------------------------------------------+
| ID                    Version   Route Type     Traffic  Cost     p95   Alerts  |
| coding-balanced       v12       dispatcher     18.2k    $42.18   8.1s  2       |
| local-first-private   v4        guard+dispatch 7.5k     $3.10    4.2s  0       |
| json-extractor-cheap  v9        cascade        91.4k    $18.09   1.2s  5       |
| premium-review        v3        cascade        812      $27.44   12s   0       |
+--------------------------------------------------------------------------------+
| Selected: coding-balanced                                                        |
| Active v12  Agents: 14  Users: 81  Fallback rate: 3.2%  Stream triggers: 41   |
| [Open graph] [View receipts] [Create draft] [Run eval] [Rollback]              |
+--------------------------------------------------------------------------------+
```

### Wireframe: Route Graph Builder

```text
+--------------------------------------------------------------------------------+
| coding-balanced / draft v13                         [Validate] [Simulate] [Save]|
+--------------------------------------------------------------------------------+
| Left Palette              Graph Canvas                                  Details |
|                            +-------------+                                      |
| [Alias]                    | dispatcher  |----fits----> local/qwen-coder        |
| [Dispatcher]               | smallest fit|----fallback> kimi/k2.6               |
| [Cascade]                  +-------------+----fallback> claude/sonnet           |
| [Alloy]                                                                        |
| [Guard]                    Warnings:                                            |
| [Concrete model]           - claude/sonnet lacks declared json_schema capability|
|                                                                            ... |
|                                                                               |
| Node details: dispatcher                                                       |
| Strategy: [smallest context that fits v]                                       |
| Sticky session: [sticky escalate v]                                            |
| Max fallback attempts: [2]                                                     |
+--------------------------------------------------------------------------------+
```

### Wireframe: Stream Policy Editor

```text
+--------------------------------------------------------------------------------+
| coding-balanced / stream policy                         Mode [buffered 256 v]  |
+--------------------------------------------------------------------------------+
| Rules                                                                          |
| +------------------------------------------------------------------------------+
| | no-deprecated-client                                                         |
| | Event: text_delta    Match: regex OldClient\(                                |
| | Action: inject reminder and retry        Max triggers: 1                     |
| | [Shadow] [Active] [Test] [Edit]                                              |
| +------------------------------------------------------------------------------+
| | shell-network-call                                                           |
| | Event: tool_call_end  Tool: shell  Match args: \bcurl\b                      |
| | Action: escalate to premium-review       Max triggers: 1                     |
| | [Shadow] [Active] [Test] [Edit]                                              |
| +------------------------------------------------------------------------------+
|                                                                                |
| Buffer behavior                                                                |
| [pass through] [buffered horizon] [semantic boundary] [full buffer]            |
| Buffer size: [256 tokens ----|-----------]                                     |
| Estimated added latency: low to medium                                         |
+--------------------------------------------------------------------------------+
```

### Wireframe: Governance Authoring Workbench

```text
+--------------------------------------------------------------------------------+
| Governance draft: no-deprecated-client                         [Ask assistant] |
+--------------------------------------------------------------------------------+
| Intent                                                                         |
| +------------------------------------------------------------------------------+
| | Do not let streamed code use OldClient(. Retry once with a reminder, then    |
| | block if the retry still violates the rule.                                  |
| +------------------------------------------------------------------------------+
| Assistant model: [local/ollama-qwen v]  Data sharing: [policy text only v]     |
| [Draft rule] [Review existing] [Generate counterexamples]                      |
+--------------------------------------------------------------------------------+
| Policy graph                                                                   |
| request.received --> route.selecting --> response.streaming --> output.final   |
|                                      |                                         |
|                                      +-- no-deprecated-client                  |
|                                          phase: stream                         |
|                                          effects: reads stream.window          |
|                                                   writes retry/reminder        |
|                                          arbitration: ordered priority 50      |
|                                          status: parallel-safe detector        |
+--------------------------------------------------------------------------------+
| Compiler and conflict review                                                   |
| ✓ schema valid       ✓ regex bounded enough for 4096 byte horizon              |
| ✓ one-shot session   ! retry_with_reminder conflicts with block rule priority  |
| Suggested fix: make block-on-second-violation the on_retry_violation action.   |
+--------------------------------------------------------------------------------+
| Draft artifact                                      | Plain-language summary   |
| kind: ingary.governance.policy                      | Holds 4096 bytes of the  |
| rules:                                              | stream, watches for      |
|   - id: no-deprecated-client                        | OldClient(, aborts       |
|     phase: response.streaming                       | before release, retries  |
|     ...                                             | once, then blocks.       |
+--------------------------------------------------------------------------------+
```

### Wireframe: Simulator

```text
+--------------------------------------------------------------------------------+
| Simulator                                                                      |
+--------------------------------------------------------------------------------+
| Model: [coding-balanced v] Version: [draft v13 v]  Session: [new run]          |
|                                                                                |
| Request                                                                         |
| +------------------------------------+  Result                                  |
| | OpenAI chat JSON or prompt         |  +--------------------------------------+ |
| |                                    |  | Selected: local/qwen-coder          | |
| |                                    |  | Reason: smallest eligible context   | |
| |                                    |  | Skipped: cheap/small, too small     | |
| |                                    |  | Fallbacks: kimi/k2.6, claude/sonnet | |
| +------------------------------------+  +--------------------------------------+ |
|                                                                                |
| [Run route only] [Run full stream] [Compare active vs draft]                    |
+--------------------------------------------------------------------------------+
```

### Wireframe: Stream Counterexample Viewer

```text
+--------------------------------------------------------------------------------+
| Generated stream checks for no-deprecated-client                 11 passed 1 failed |
+--------------------------------------------------------------------------------+
| Failed property: violating bytes must not be released before trigger            |
| Minimal stream: "safe Old" + "Client("                                          |
| Chunk sizes: [8, 7]                                                             |
| Holdback: 8 bytes                                                               |
|                                                                                |
| Timeline                                                                        |
| held:     safe Old                                                              |
| released: safe                                                                  |
| held:          OldClient(                                                       |
| trigger:              ^ regex OldClient\(                                      |
|                                                                                |
| Diagnosis: holdback is smaller than the trigger span plus chunk boundary risk.  |
| Suggested fixes: increase holdback to 16 bytes, or switch to full_buffer mode.  |
| [Pin as regression] [Apply suggested fix] [Ask assistant to explain]            |
+--------------------------------------------------------------------------------+
```

### Wireframe: Receipt Explorer

```text
+--------------------------------------------------------------------------------+
| Receipts                                                        [Export] [Filter]|
+--------------------------------------------------------------------------------+
| Agent [all v] User [all v] Session [all v] Status [all v] Model [all v]        |
| Time       Agent       User     Model             Selected      Status Triggers |
| 12:41:02   repo-coder  user-42  coding-balanced   local/qwen    success 0       |
| 12:39:18   repo-coder  user-42  coding-balanced   local/qwen    retry   1       |
| 12:38:44   extractor   svc-api  json-extractor    managed/cheap blocked 1       |
+--------------------------------------------------------------------------------+
| Receipt detail                                                                  |
| Caller: calciforge / repo-coder / user-42 / agent-session-7                    |
| Request estimate: 18,420 tokens   Tools: yes   Stream: yes                     |
| Decision timeline:                                                              |
|   1. dispatcher selected local/qwen because request fit 32k context             |
|   2. stream rule no-deprecated-client matched at offset 1834                    |
|   3. content was not released to consumer                                       |
|   4. retry injected reminder                                                    |
|   5. second attempt completed                                                   |
|                                                                                |
| [View raw receipt] [Replay in simulator] [Create rule from event]               |
+--------------------------------------------------------------------------------+
```

### Wireframe: Provider Adapter View

```text
+--------------------------------------------------------------------------------+
| Providers                                                   [New provider]      |
+--------------------------------------------------------------------------------+
| ID          Kind        Base URL                         Models  Health  Owner |
| local       openai      http://127.0.0.1:11434/v1        3       ok      local |
| managed     litellm     https://gateway.example.invalid  14      ok      team  |
| openrouter  openrouter  https://openrouter.example.invalid/v1  50 warn provider|
+--------------------------------------------------------------------------------+
| Selected: managed                                                               |
| Credential owner: provider                                                      |
| Auth: api_key_file configured                                                   |
| Capabilities: chat, tools, json_schema, streaming                               |
| [Test request] [Sync models] [View receipts] [Edit]                             |
+--------------------------------------------------------------------------------+
```

### Wireframe: Artifact Hub

```text
+--------------------------------------------------------------------------------+
| Synthetic Model Hub                                      [Import file] [Publish]|
+--------------------------------------------------------------------------------+
| Search [coding agent................] Use case [all v] Trust [verified v]      |
+--------------------------------------------------------------------------------+
| Artifact              Version  Use case      Requires              Trust        |
| coding-balanced       1.0.0    coding agent  local coder + long ctx verified    |
| json-extractor-safe   0.4.2    extraction    json schema model     community    |
| tool-call-guard       0.2.0    agent tools   stream policy VM      experimental |
+--------------------------------------------------------------------------------+
| Selected: coding-balanced                                                       |
| Provider roles: small_local_coder, long_context_coder                           |
| Tested with: Ingary clean Rust, LiteLLM downstream, local Ollama                |
| Import creates draft only. Map provider roles before simulation or activation.  |
| [View manifest] [Map providers] [Import as draft] [Run eval pack]              |
+--------------------------------------------------------------------------------+
```

## MVP Scope

### MVP 0: Design Spike

- Choose name.
- Extract neutral schemas from Calciforge concepts.
- Decide whether to begin inside Calciforge workspace or a new repository.
- Write compatibility matrix for Calciforge integration paths:
  Rust API, HTTP, or both.
- Compare four backend foundations before committing:
  - clean Rust service/library prototype
  - clean Go gateway prototype
  - clean Elixir gateway prototype
  - TensorZero-based foundation spike
  - LiteLLM-based foundation spike

Prototype evaluation criteria:

- OpenAI-compatible serving fidelity.
- Route graph and namespace ergonomics.
- Stream governance hooks.
- Receipt and caller traceability support.
- Provider adapter reuse.
- UI/control-plane fit.
- Operational packaging.
- Maintenance risk and fork burden.

### Prototype Findings

Initial prototype pass:

| Candidate | Shape | Result |
|---|---|---|
| Rust clean backend | Axum/Tokio/Serde mock gateway | Strong fit for a reusable core library, Calciforge embedding, streaming safety, and single-binary distribution. More implementation ceremony than Go/Elixir. |
| Go clean backend | Standard-library `net/http` mock gateway | Strong fit for a boring deployable gateway with small operational footprint. Less compelling for deep policy/stream abstractions than Rust or Elixir. |
| Elixir clean backend | Plug/Cowboy mock gateway with supervised in-memory receipts | Strong fit for stream governance, backpressure, supervision, provider lifecycles, and graceful degradation. Distribution and Calciforge embedding are weaker than Rust/Go. |
| LiteLLM foundation spike | Config and namespace evaluation | Do not fork as the first foundation. Use as a downstream provider gateway and optionally as a front gateway that exposes `ingary/*` models. |
| TensorZero foundation spike | Config and adapter-contract evaluation | Do not fork as the first foundation. Use as an optional downstream/eval/observability engine while Ingary owns synthetic model semantics and stream governance. |
| React frontend prototype | Vite/React/TypeScript mock UI | Good enough to validate catalog, simulator, receipts, caller provenance, provider list, and route graph assumptions against the OpenAPI contract. |

Current backend bias:

- Choose **Rust** if the core route/stream engine must be embeddable in
  Calciforge and distributed as a compact self-hosted binary.
- Choose **Elixir** if stream governance, long-lived provider supervision,
  backpressure, and operator-facing control-plane behavior become the dominant
  product differentiator.
- Choose **Go** if the priority is a simple, conservative HTTP gateway with
  minimal runtime assumptions.
- Do not start by forking LiteLLM or TensorZero. Integrate with them and borrow
  architectural lessons, but keep the synthetic model contract, route receipts,
  caller provenance, shareable artifacts, and stream governance as Ingary-owned
  semantics.

### MVP 1: Headless Core

- `ingary-core` with config parsing, validation, route graph planning, receipts.
- `dispatcher`, `cascade`, `alias`, and `concrete_model`.
- Token estimator trait with char/byte estimators.
- Simulation API.
- Unit tests and property tests for route graph safety.

Exclude initially:

- UI.
- programmable policy.
- weighted alloys, unless lifted cheaply.
- native provider adapters beyond OpenAI-compatible HTTP and mock.

### MVP 2: Standalone Gateway

- OpenAI-compatible `/v1/chat/completions`.
- `/v1/models`.
- `/v1/synthetic/simulate`.
- SQLite receipt store.
- OpenAI-compatible HTTP adapter.
- Basic streaming normalization.
- Receipt persistence for route decisions and attempts.

### MVP 3: Stream Governance

- Normalized stream event model.
- Buffered horizon and full buffer modes.
- Declarative regex rules.
- `inject_reminder_and_retry`.
- `escalate`.
- Receipt events for every trigger.
- Shadow mode.

### MVP 4: UI

- Model catalog.
- Provider adapter view.
- Route graph read-only view.
- Simulator.
- Receipt explorer.
- Stream policy editor for declarative rules.
- Artifact hub/import-export view.

### MVP 5: Calciforge Integration

Options to decide at that time:

- Embed `ingary-core` and keep Calciforge's HTTP serving path.
- Point Calciforge's provider route to the standalone product.
- Hybrid: Calciforge embeds planner but delegates receipt UI to standalone
  control plane.

The right answer depends on operational maturity, packaging, and whether the
new product's gateway is already more robust than Calciforge's internal path.

Near-term recommendation: integrate through Calciforge's existing
OpenAI-compatible provider-adapter boundary first. Calciforge can treat Ingary
as a downstream OpenAI-compatible backend while Calciforge remains the outer
agent/security gateway:

```text
agent / channel
  -> Calciforge
  -> Calciforge provider adapter pointed at Ingary /v1
  -> Ingary synthetic model
  -> Ingary downstream provider adapter or mock/local model
```

This gives real Calciforge traffic to Ingary without ripping out Calciforge's
current synthetic model code immediately. It also keeps rollback simple: disable
the Ingary provider route and return to Calciforge's existing model path.

Requirements for that bridge:

- Register Ingary as one OpenAI-compatible provider/backend in Calciforge.
- Send public model names such as `coding-balanced` or
  `ingary/coding-balanced` to Ingary unchanged.
- Forward caller traceability headers: tenant, application, consuming agent,
  consuming user, session, run, and client request ID where Calciforge knows
  them.
- Surface Ingary receipt IDs in Calciforge logs/receipts so a Calciforge run can
  be correlated with an Ingary route receipt.
- Avoid duplicating retries/fallbacks in both layers for the same failure class
  until receipt semantics are explicit.

Later, once Ingary has durable storage, stream governance, and real provider
adapters, Calciforge can delete its internal synthetic model implementation and
either keep calling Ingary over HTTP or embed the Rust/core library if that
becomes the lower-friction path.

## Requirements

### Functional Requirements

- Accept OpenAI-compatible chat requests.
- Preserve OpenAI-compatible behavior for ordinary clients.
- Accept and normalize caller context for tenant, consuming application,
  consuming agent, consuming user, session, run, and request tags.
- Resolve requested synthetic models to route plans.
- Reject route graphs with cycles.
- Reject concrete models without declared context windows unless configured as
  unknown-capacity and excluded from fit-based dispatch.
- Skip targets whose effective context window cannot fit the request.
- Preserve route version immutability after publication.
- Produce receipts for simulations and live requests.
- Index receipts and logs by caller context so operators can filter by
  consuming agent, consuming user, session/run, tenant, model, route version, and
  provider.
- Import and export synthetic model manifests without credentials or private
  deployment identifiers.
- Import shareable artifacts as drafts only, with explicit provider-role
  mapping and validation before activation.
- Support file-based config.
- Support UI-authored config that compiles to the same graph model.
- Support provider adapter endpoint auth without exposing upstream secrets in
  receipts.
- Normalize provider failure classes.
- Support streaming and non-streaming responses.
- Prevent stream-policy-violating output from reaching the consumer when using
  buffered or full-buffer modes.

### Non-Functional Requirements

- Route planning must be deterministic for the same request context and graph
  version unless an explicit randomization node is used.
- Route receipts must not capture prompts or completions by default.
- Caller traceability metadata must be visible without requiring prompt or
  completion capture.
- Programmable policy execution must be deterministic and resource-bounded.
- The gateway must fail closed on invalid config.
- The UI must clearly distinguish active, draft, and canary versions.
- The UI must clearly distinguish local definitions, imported artifacts, and
  hub-sourced updates.
- The product must run locally with SQLite and no external services.
- Team deployments should support Postgres.
- Redis must be optional and ephemeral, not a durable receipt or model-definition
  dependency.
- DuckDB should be treated as an analytics/export companion unless a later
  prototype proves it can simplify the product without weakening live request
  durability.
- Receipt-list queries for the primary UI filters must use indexed structured
  fields, not full JSON scans.
- Provider adapters must not log bearer credentials.
- Streaming policy latency must be configurable and visible.

## Testing Plan

### Unit Tests

- Config parsing and validation.
- Route graph cycle detection.
- Alias resolution.
- Dispatcher fit ordering.
- Cascade fallback ordering.
- Effective context-window calculations.
- Token estimator safety margins.
- Failure-class normalization.
- Receipt schema serialization.
- Receipt store interface behavior: insert, retrieve by ID, list with stable
  ordering, filter by caller dimensions, filter by model/version/status, and
  enforce retention boundaries.
- Storage migration tests from empty database and previous schema.
- Caller context normalization and provenance labels for auth, headers,
  metadata, provider records, and anonymous fallback.
- Synthetic model artifact schema validation, import, export, provider-role
  mapping, and secret/private-identifier rejection.
- Stream ring-buffer release math.
- Declarative stream rule matching.
- Policy host API allowlist.

### Property Tests

- Route planner never selects a target whose effective context window is below
  the request estimate.
- Published graph versions are immutable.
- Cycle detection terminates for arbitrary graph shapes.
- Ring buffer never releases bytes/events after a matching violation when the
  policy mode promises non-release.
- Retry limits prevent infinite loops.
- Receipt event ordering matches state transitions.
- Receipt summary indexes remain equivalent to the full receipt/event payload
  for generated caller/model/status filters.
- Storage round-trips preserve receipt schema version, caller provenance,
  skipped targets, stream triggers, and provider attempts.
- Generated sink projections match the receipt oracle for configured event
  streams, search indexes, and telemetry/log sinks.
- Sink redaction properties match storage redaction properties for generated
  prompt, completion, tool-call, credential-like, and private-identifier inputs.
- Sink replay from durable receipt events rebuilds the same observable
  projection as live fanout.

### Integration Tests

- OpenAI-compatible non-streaming chat request through mock adapter.
- OpenAI-compatible streaming request through mock adapter.
- Streaming tool-call assembly and validation.
- Provider failure triggers configured cascade fallback.
- Context-exceeded failure is classified correctly.
- `inject_reminder_and_retry` creates a second attempt with modified system
  context.
- Escalation switches to configured target and records receipt.
- Simulator and live execution produce comparable decision records.
- SQLite receipt persistence and retrieval.
- SQLite receipt filtering by consuming agent, consuming user, session, run,
  synthetic model, version, status, provider, concrete model, and time range.
- Postgres migration and query compatibility for the same logical receipt
  schema before declaring the server deployment path stable.
- Optional Redis loss/restart does not lose receipts, model definitions, or
  active rollout state.
- Search sink receives receipt summaries and can answer the receipt explorer's
  expected filters after bounded eventual-consistency delay.
- Event-stream sink receives ordered per-receipt events and handles duplicate
  delivery idempotently.
- Sink outage follows configured queue/drop/backpressure policy and records
  health state without corrupting durable receipts.

### UI Tests

- Model catalog renders active/draft/canary states.
- Route graph view flags invalid nodes and missing capabilities.
- Simulator compares active and draft versions.
- Receipt explorer shows route and stream trigger timeline.
- Receipt explorer filters by consuming agent, consuming user, session/run,
  source/provenance, and synthetic model.
- Receipt explorer keeps list queries responsive against persisted receipt
  metadata without requiring prompt/completion capture.
- Artifact hub browse/import/export/update flows land in draft mode and show
  provider-role mapping.
- Stream policy editor validates regex and retry limits.
- Provider adapter view hides credential values.

### Compatibility Tests

- Standard OpenAI SDK can call `/v1/chat/completions`.
- Streaming shape remains compatible with OpenAI SDK expectations.
- Calciforge can call the standalone gateway as an OpenAI-compatible provider.
- Calciforge can embed core planner APIs without HTTP.
- LiteLLM/Helicone/OpenRouter style OpenAI-compatible adapters pass smoke
  tests without provider-specific duplicated code.

### Security And Privacy Tests

- Receipts do not include prompts/completions unless content capture is enabled.
- Redaction runs before content persistence.
- Caller context fields are persisted and indexed without requiring prompt or
  completion capture.
- Logs omit bearer tokens and provider headers.
- Programmable policy cannot access filesystem/network/process APIs.
- Admin API cannot publish invalid graph versions.
- Serving API cannot access admin endpoints with serving credentials.
- Exported artifacts do not include credentials, private endpoints, or captured
  real-user content by default.

## Open Design Questions

- Product name.
- Should the first repository be separate immediately, or should the first
  extraction branch live inside Calciforge until the interfaces stabilize?
- Should provider adapters live in the core product or in optional crates?
- Should Calciforge consume the Rust API first or the HTTP boundary first?
- How much of Calciforge's current provider config should be accepted as a
  migration format?
- Should programmable policy ship in MVP 3 or wait until declarative stream
  rules prove the event model?
- Should weighted alloys be in MVP 1, or wait until route receipts and stream
  policy are solid?
- What is the minimum UI that proves the product is differentiated?

## Hosted Service And Marketplace Option

Self-hosting should remain the core open-source promise, but a hosted Ingary
service could become a credible sustainability path if the product proves useful
for sophisticated agent builders.

Hosted mode would add value by removing operator burden:

- no local gateway deployment
- managed provider credentials and rate limits
- durable receipt storage and search
- managed artifact hub/import flows
- team auth, billing, and organization policy

It also changes the marketplace story. In self-hosted mode, shared synthetic
model artifacts should be inspectable by default: trust should come from tests,
signatures, provenance, and reputation rather than opaque policy blobs. In a
hosted marketplace, an author could offer a synthetic model as a hosted policy
service without disclosing complex policy implementation details to consumers.
Receipts must make that explicit: policy was evaluated remotely, policy logic
was opaque to the consuming operator, and the author/provider identity and
version were recorded.

This is not a near-term MVP requirement, but it is worth preserving in the
architecture:

- policy engines are pluggable behind the same ABI
- receipts distinguish inspectable local policy from opaque hosted policy
- manifests can reference remote policy services as explicit dependencies
- hub artifacts can be free/open, private/internal, or hosted/commercial
- local self-hosted execution never depends on the hosted marketplace

## Naming Criteria

The name should signal model composition, routing, and observability without
feeling like a Calciforge sub-brand. It should work for a CLI, server binary,
Rust crates, and UI.

Useful associations:

- synthetic models
- route receipts
- model contracts
- stream governance
- switching/escalation
- graph/version control

Avoid names that imply:

- generic proxy only
- prompt management only
- security product only
- Calciforge-only dependency
- provider marketplace

## Initial Critique

The strongest reason to build this is not that nobody routes models. Many
products do. The reason is that existing products generally treat routing as a
gateway feature. This product would treat model behavior as a versioned,
explainable contract.

The risk is scope. Provider adapters, stream governance, receipts, evals,
rollouts, and UI are each substantial. The way to keep the product real is to
make receipts and simulation the center from the start. If those are compelling,
the UI and stream governance have a reason to exist. If they are not
compelling, the product is probably not differentiated enough to justify a
separate project.
