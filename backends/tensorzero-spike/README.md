# TensorZero Foundation Spike

This spike evaluates TensorZero as a foundation for Ingary-style synthetic
models. It is not a fork and does not vendor upstream code. The goal is to
decide whether Ingary should build on top of TensorZero, extend it, or treat it
as a downstream gateway/provider.

Sources reviewed:

- `contracts/openapi.yaml`
- `docs/rfcs/ingary-extraction.md`
- TensorZero docs: <https://www.tensorzero.com/docs>
- TensorZero gateway docs: <https://www.tensorzero.com/docs/gateway>
- TensorZero OpenAI-compatible API docs:
  <https://www.tensorzero.com/docs/gateway/api-reference/inference-openai-compatible>
- TensorZero functions/variants docs:
  <https://www.tensorzero.com/docs/gateway/configure-functions-and-variants>
- TensorZero retries/fallbacks docs:
  <https://www.tensorzero.com/docs/gateway/guides/retries-fallbacks>
- TensorZero OpenAI-compatible provider guide:
  <https://www.tensorzero.com/docs/gateway/guides/providers/openai-compatible>
- TensorZero repository overview: <https://github.com/tensorzero/tensorzero>

## What TensorZero Already Provides

TensorZero is close to the infrastructure half of the Ingary idea:

- **Gateway**: OpenAI-compatible `/openai/v1/chat/completions`, native
  `/inference`, multiple providers, OpenAI-compatible upstreams, streaming,
  tool use, structured output, retries, fallbacks, and low-latency Rust gateway
  packaging.
- **Observability**: inference and feedback records in operator-owned storage,
  UI/programmatic querying, datasets built from traces, OpenTelemetry trace
  export, and Prometheus metrics.
- **Evals**: inference-level and workflow-level evaluations with heuristic or
  LLM-judge evaluators.
- **Routing and experiments**: functions, variants, provider routing, variant
  fallback, retries, static/adaptive A/B tests, namespace-scoped experiment
  selection, and episode-level consistency for multi-step workflows.
- **Config ergonomics**: GitOps-oriented TOML for models, providers, functions,
  variants, metrics, tools, auth, rate limits, storage, and gateway behavior.

Those are substantial primitives. A clean Ingary backend would otherwise have
to rebuild provider normalization, traces, eval datasets, variant experiments,
gateway deployment, and basic UI surfaces.

## Where Ingary Fits

The best fit is to map a public synthetic model to a TensorZero function:

- `coding-balanced` becomes a function, because TensorZero functions are the
  stable application-facing unit.
- concrete Ingary targets such as `local/qwen-coder` and `managed/kimi-k2.6`
  become TensorZero models/providers or function variants.
- Ingary caller/session metadata maps partly to TensorZero tags, namespace,
  episode IDs, and OTLP trace metadata.
- Ingary eval history can use TensorZero datasets/evaluations instead of
  inventing a separate eval runner immediately.

The sketch in [config/tensorzero.toml](config/tensorzero.toml) shows the
closest direct representation:

```text
OpenAI client model: tensorzero::function_name::ingary_coding_balanced
Ingary public model: ingary/coding-balanced
TensorZero function: ingary_coding_balanced
TensorZero variants: local_qwen_coder, managed_kimi_k2_6
```

Ingary would still need a thin adapter in front of TensorZero if it wants the
contracted public path and model ID to remain exactly:

```text
POST /v1/chat/completions
model = "ingary/coding-balanced"
```

TensorZero's OpenAI-compatible endpoint expects its own model prefix syntax,
for example `tensorzero::function_name::...`, so an adapter would translate
Ingary model IDs to TensorZero function calls and translate TensorZero
responses/metadata back into Ingary receipts.

## Where Concepts Conflict

The core conflict is product vocabulary. TensorZero exposes functions,
variants, models, providers, metrics, and experiments. Ingary wants synthetic
models as the public contract and route graph as the explainable behavior
behind that contract.

Specific mismatches:

- **Public model namespace**: Ingary wants `/v1/models` to list synthetic
  models such as `coding-balanced` or `ingary/coding-balanced`. TensorZero's
  native OpenAI-compatible convention uses `tensorzero::function_name::...` or
  `tensorzero::model_name::...`.
- **Context-window dispatcher**: Ingary's recommended first route is
  `smallest_context_that_fits` by estimated prompt length. TensorZero has
  routing, experiments, fallbacks, and variants, but the reviewed docs do not
  show a first-class conditional dispatcher based on estimated prompt tokens.
- **Receipts**: TensorZero records inference/feedback data, raw usage, variant
  name, provider/model inference metadata, and traces. Ingary receipts are a
  product contract: synthetic model, version, caller provenance, selected
  concrete model, skipped branches, stream-policy triggers, attempts, and final
  status. That would require an Ingary receipt layer even if TensorZero stores
  the underlying traces.
- **Simulation**: Ingary requires `/v1/synthetic/simulate` to resolve a route
  without provider calls. TensorZero has dry-run/debug and eval workflows, but
  the OpenAI-compatible dry-run still executes the downstream inference.
- **Stream governance**: TensorZero supports streaming. Ingary needs a
  normalized stream event model plus policy actions such as buffered horizon,
  semantic boundary, inject-reminder-and-retry, escalation, and receipt events.
- **Admin model shape**: Ingary needs admin APIs centered on synthetic model
  route graphs. TensorZero's config/UI is centered on functions/variants and
  model providers.

## Minimal Adapter Shape

A feasible non-fork architecture is:

```text
client
  -> Ingary adapter API (/v1/chat/completions, /v1/synthetic/simulate, receipts)
  -> TensorZero gateway (/openai/v1/chat/completions or /inference)
  -> provider/local runtime
```

The adapter owns:

- `ingary/` prefix stripping and flat model aliases.
- route graph simulation and context-window dispatch.
- caller header extraction from `X-Ingary-*`.
- durable Ingary receipts.
- stream governance before bytes reach the caller.
- translation from Ingary model IDs to TensorZero functions/variants.

TensorZero owns:

- provider calls.
- provider credentials and upstream model normalization.
- fallback/retry mechanics after the adapter selects a route or variant set.
- inference traces, usage, feedback, datasets, evals, and UI observability.

For `coding-balanced`, the adapter can estimate prompt length and either:

1. call TensorZero with `tensorzero::variant_name` pinned to
   `local_qwen_coder` or `managed_kimi_k2_6`; or
2. call distinct TensorZero functions, one per branch; or
3. let TensorZero sample/fallback between variants and accept that Ingary
   receipts will be less deterministic.

Option 1 is the cleanest for Ingary semantics, but it means Ingary, not
TensorZero, remains the route planner.

## Risks Of Forking Or Deep Extension

- **High fork burden**: TensorZero is broad: gateway, UI, ClickHouse/Postgres,
  evals, optimization, auth, rate limits, provider integrations, and client
  compatibility. Carrying a fork would turn Ingary into a TensorZero
  distribution project.
- **Upstream velocity risk**: provider APIs, OpenAI-compatible parameters,
  eval workflows, and UI surfaces change quickly. A fork would have to track
  upstream security and provider updates.
- **Concept drift**: adding synthetic-model route graphs directly into
  TensorZero could blur the Ingary product thesis unless upstream accepts the
  vocabulary as first-class.
- **Receipt contract risk**: TensorZero observability records are useful but
  not the same as Ingary receipts. If Ingary relies on internal trace schema
  details, it may inherit breaking changes.
- **Streaming policy risk**: stream governance needs to sit before callers see
  output. Retrofitting that into a gateway optimized for provider passthrough
  could be invasive.
- **Deployment complexity**: TensorZero's observability/evals value is strongest
  with storage and UI. That is a heavier default than a small headless synthetic
  route planner.

## Recommendation

Do not fork TensorZero for Ingary's first backend.

Use TensorZero as an optional downstream gateway/provider adapter and eval/
observability backend. Build Ingary's headless core separately around synthetic
models, route graph simulation, receipts, caller provenance, and stream
governance. Then add a TensorZero adapter that can:

- send selected branches to TensorZero functions/variants;
- attach caller and route metadata as tags/episode/trace attributes where
  possible;
- import TensorZero inference IDs, usage, variant names, and eval outputs into
  Ingary receipts/admin views.

This preserves Ingary's differentiated contract while avoiding a large fork.
TensorZero is a strong foundation for provider execution and learning loops,
but it should not be the first source of truth for synthetic model semantics.
