# LiteLLM Spike For Ingary Synthetic Models

This is a fork/foundation evaluation, not a fork of upstream LiteLLM. It asks
whether LiteLLM should become the base runtime for Ingary-style synthetic
models or remain an adjacent gateway that Ingary can sit in front of or behind.

The contract evaluated here is the local draft in
`../../contracts/openapi.yaml`: OpenAI-compatible serving endpoints, public
synthetic model IDs, caller traceability, route simulations, receipts, and admin
visibility into providers and synthetic models.

## LiteLLM Capabilities Relevant To Ingary

Sources reviewed on 2026-05-13:

- LiteLLM getting started: <https://docs.litellm.ai/>
- proxy config: <https://docs.litellm.ai/docs/proxy/configs>
- virtual keys: <https://docs.litellm.ai/docs/proxy/virtual_keys>
- callbacks: <https://docs.litellm.ai/docs/observability/callbacks>
- custom callbacks: <https://docs.litellm.ai/docs/observability/custom_callback>
- OpenAI-compatible endpoint adapter:
  <https://docs.litellm.ai/docs/providers/openai_compatible>

### OpenAI-Compatible Proxying

LiteLLM is already strong at this layer. The proxy exposes an
OpenAI-compatible gateway, normalizes provider request/response shapes, supports
chat completions, responses, streaming, embeddings, images, audio, batches, and
more, and maps provider exceptions into OpenAI-style errors.

For Ingary, this means LiteLLM can cover the commodity gateway substrate:

- client SDK compatibility
- provider fan-out
- streaming pass-through
- provider error normalization
- request timeout and retry settings
- one gateway process plus optional admin UI

This is useful but not differentiated. Ingary's value is not "another
OpenAI-compatible proxy"; it is stable synthetic model contracts with route
receipts, simulation, context-aware routing, and bounded stream governance.

### Custom OpenAI-Compatible Backends

LiteLLM can register arbitrary OpenAI-compatible backends through `model_list`
entries using `litellm_params.model: openai/<upstream-model>` plus `api_base`
and `api_key`. That makes Ingary easy to expose behind LiteLLM as a managed
backend:

```yaml
model_list:
  - model_name: ingary/coding-balanced
    litellm_params:
      model: openai/ingary/coding-balanced
      api_base: os.environ/INGARY_API_BASE
      api_key: os.environ/INGARY_API_KEY
```

LiteLLM can also be downstream of Ingary as a provider adapter. In that shape,
Ingary keeps the public synthetic model namespace and sends selected concrete
model requests to LiteLLM model groups.

### Virtual Keys

LiteLLM's virtual keys are a real fit for the "enterprise gateway in front"
topology. Keys can be generated with allowed model lists and metadata, and
LiteLLM uses a database-backed proxy mode for key state and spend tracking.

Mapping to Ingary:

- `models` can restrict a key to `ingary/*` synthetic models.
- `metadata` can carry caller or tenant hints when clients cannot send Ingary
  headers.
- `team_id`, `user_id`, and key-level data can become receipt caller sources
  when LiteLLM sits in front.

Limitation: LiteLLM key metadata is not an Ingary receipt. It can identify who
entered the gateway, but it does not explain synthetic route decisions unless
Ingary is still the component making and recording those decisions.

### Budgets And Rate Limits

LiteLLM provides budget and limit primitives around virtual keys and gateway
usage, including maximum budget, budget duration, tokens-per-minute,
requests-per-minute, and parallel request controls.

Mapping to Ingary:

- Good as a front-gateway quota layer.
- Good as a downstream provider budget guard when Ingary calls LiteLLM.
- Not enough for synthetic model policy by itself, because Ingary needs budget
  decisions to be tied to route graph state and receipt events.

Recommendation: ingest LiteLLM budget/key/team identifiers as receipt metadata,
but keep Ingary's own route-policy budget checks explicit where a budget affects
route selection, fallback, escalation, or stream policy.

### Metadata

LiteLLM accepts virtual-key metadata and can pass request metadata through its
callbacks and hooks. This is useful for caller traceability, especially when
LiteLLM is the organization's required ingress.

Ingary should preserve source confidence:

- trusted gateway auth or key metadata: `provider_key`
- Ingary-specific headers: `header`
- OpenAI request body metadata: `body_metadata`
- missing identity: `derived_anonymous`

The local contract currently uses `X-Ingary-*` headers. If Ingary sits behind
LiteLLM, the deployment must configure LiteLLM and any clients to preserve or
inject those headers/metadata. Without that, receipts will only know the
LiteLLM key/team/user dimensions.

### Callbacks And Hooks

LiteLLM has predefined observability callbacks and custom callback extension
points. They are useful for telemetry export, spend/cost accounting, and
cross-cutting policy hooks.

They are not a clean substitute for Ingary stream governance:

- Ingary needs normalized stream events before release to the consumer.
- Ingary needs bounded state transitions such as retry, escalate, block, and
  mark receipt.
- Ingary needs receipts that connect route planning, attempts, stream triggers,
  and final status.

Callbacks can export Ingary events or bridge LiteLLM metadata into Ingary, but
making callbacks the core synthetic model engine would couple the product to
LiteLLM internals and lifecycle.

### Fallbacks

LiteLLM supports retry settings, fallback mappings, and context-window
fallbacks in proxy config. This is directly useful for provider reliability.

Synthetic models need a stricter abstraction:

- fallback is part of a versioned route graph
- skipped targets need reasons
- context-window decisions need deterministic simulation
- fallback attempts must appear in receipts
- stream-policy abort/retry/escalate must be distinguishable from provider
  errors

LiteLLM fallback can remain an inner provider behavior, but Ingary should own
public synthetic fallback semantics.

## Config Sketches

These examples are intentionally non-runnable sketches. They avoid real domains,
real keys, and private deployment identifiers. Use environment variables for
secrets and operator-specific endpoints.

### Topology A: Ingary In Front, LiteLLM Downstream

Use this when Ingary owns the public model contract and LiteLLM is the managed
provider gateway.

See `ingary-front-litellm-downstream.yaml`.

Public client:

```text
OpenAI client -> Ingary /v1 -> LiteLLM /v1 -> providers
model = coding-balanced
```

Ingary exposes `coding-balanced` or `ingary/coding-balanced`. Its route graph
selects concrete targets such as `local/qwen-coder` or `managed/kimi-k2.6`.
The `managed/*` targets call LiteLLM model groups.

This is the best match for Ingary's product thesis because route planning,
simulation, receipts, and stream policy stay at Ingary's boundary.

### Topology B: LiteLLM In Front, Ingary As Managed Backend

Use this when an organization already requires LiteLLM for auth, virtual keys,
budgets, and central gateway access.

See `litellm-front-ingary-backend.yaml`.

Public client:

```text
OpenAI client -> LiteLLM /v1 -> Ingary /v1 -> providers or local runtime
model = ingary/coding-balanced
```

LiteLLM registers Ingary as an OpenAI-compatible provider with a prefixed model
namespace. LiteLLM handles virtual keys and budgets. Ingary still handles
synthetic route planning and receipts after the request reaches it.

This topology is acceptable, but caller traceability depends on LiteLLM passing
metadata or headers through.

## Namespace Probe

`namespace_probe.py` demonstrates the namespace rule without installing
LiteLLM:

```bash
python3 namespace_probe.py coding-balanced ingary/coding-balanced gpt-5
```

Expected behavior:

- `coding-balanced` normalizes to the Ingary synthetic model in flat mode.
- `ingary/coding-balanced` normalizes to the same synthetic model in prefixed
  mode.
- other model IDs are rejected by Ingary but may be valid LiteLLM/provider IDs
  outside the Ingary namespace.

## Forking Or Deep Extension Risks

- **Product boundary risk**: LiteLLM optimizes for gateway/provider breadth.
  Ingary's differentiator is versioned synthetic model behavior with receipts.
  Deeply embedding that into LiteLLM may blur the public abstraction into a
  provider catalog.
- **Upgrade drag**: LiteLLM is active and broad. A fork will inherit frequent
  provider/API churn, security patches, and migration work unrelated to Ingary's
  core product.
- **Security surface area**: a fork would own a large gateway, auth, callback,
  admin UI, persistence, and provider integration surface. That increases
  review burden before Ingary has validated its narrower route/receipt engine.
- **Callback coupling**: callbacks are useful integration points, but receipts
  and stream governance need first-class state machines. Implementing those as
  callback side effects would make behavior harder to reason about and test.
- **Namespace pressure**: LiteLLM's model namespace naturally lists routable
  model groups. Ingary should list synthetic models by default and keep concrete
  provider models behind admin APIs and receipts.
- **Language/runtime mismatch**: Ingary's likely production core benefits from
  explicit typed route graphs, bounded policy execution, and strict receipt
  schemas. A Python gateway fork can prototype quickly, but it is not the best
  long-term host for the security-sensitive core.
- **Enterprise feature ambiguity**: some LiteLLM operational features are
  enterprise or database-backed. Ingary should not make its core synthetic model
  contract depend on a feature tier it does not control.

## Recommendation

Do not fork LiteLLM as the foundation for Ingary.

Use LiteLLM as an integration target in both directions:

1. **Primary default**: Ingary in front, LiteLLM downstream provider adapter.
   Ingary owns synthetic model IDs, route simulation, receipts, and stream
   governance. LiteLLM owns broad provider access, provider credentials, retries
   that are internal to a concrete target, virtual keys for downstream access
   where useful, and gateway dashboards.
2. **Enterprise compatibility**: LiteLLM in front, Ingary registered as an
   OpenAI-compatible backend under `ingary/*`. LiteLLM owns ingress auth,
   virtual keys, budgets, and organization-wide gateway policy. Ingary still
   owns synthetic route decisions and receipts.

The next useful prototype is a tiny Ingary provider adapter that calls a local
LiteLLM proxy and records the LiteLLM model group, key/team metadata, and
response headers in the Ingary receipt. That validates the integration without
committing to an upstream fork.
