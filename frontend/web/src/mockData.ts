import type {
  Provider,
  Receipt,
  ReceiptSummary,
  SimulationRequest,
  SimulationResult,
  SyntheticModel,
  SyntheticModelSummary,
} from "./types";

export const models: SyntheticModel[] = [
  {
    id: "coding-balanced",
    active_version: "2026-05-13.a",
    description: "Local-first coding model with long-context managed fallback.",
    public_namespace: "flat",
    route_graph: {
      root: "entry",
      nodes: [
        { id: "entry", type: "alias", targets: ["fit-dispatch"] },
        {
          id: "fit-dispatch",
          type: "dispatcher",
          targets: ["local-qwen-coder", "managed-kimi"],
          strategy: "smallest_context_window_that_fits",
        },
        {
          id: "local-qwen-coder",
          type: "concrete_model",
          provider_id: "local",
          upstream_model_id: "qwen-coder",
          context_window: 32768,
        },
        {
          id: "managed-kimi",
          type: "concrete_model",
          provider_id: "managed",
          upstream_model_id: "kimi-k2.6",
          context_window: 262144,
        },
      ],
    },
    stream_policy: {
      mode: "buffered_horizon",
      buffer_tokens: 96,
      rules: [
        { id: "tool-secret-boundary", action: "abort_retry", trigger: "secret_pattern" },
        { id: "license-guard", action: "mark_receipt", trigger: "license_text" },
      ],
    },
  },
  {
    id: "local-first-private",
    active_version: "2026-05-08.b",
    description: "Privacy-sensitive route with explicit cloud escalation gate.",
    public_namespace: "prefixed",
    route_graph: {
      root: "privacy-guard",
      nodes: [
        { id: "privacy-guard", type: "guard", targets: ["private-cascade"], policy: "allow_cloud_escalation == true" },
        { id: "private-cascade", type: "cascade", targets: ["local-small", "managed-safe"] },
        {
          id: "local-small",
          type: "concrete_model",
          provider_id: "local",
          upstream_model_id: "llama-local",
          context_window: 16384,
        },
        {
          id: "managed-safe",
          type: "concrete_model",
          provider_id: "managed",
          upstream_model_id: "safe-large",
          context_window: 128000,
        },
      ],
    },
    stream_policy: { mode: "semantic_boundary", buffer_tokens: 160, rules: [{ id: "pii-final", action: "block_final" }] },
  },
  {
    id: "json-extractor-cheap",
    active_version: "2026-05-01.a",
    description: "Low-cost extraction route with strict JSON final status checks.",
    public_namespace: "flat",
    route_graph: {
      root: "cheap-alloy",
      nodes: [
        { id: "cheap-alloy", type: "alloy", targets: ["mock-fast", "mock-cheap"], weights: { "mock-fast": 70, "mock-cheap": 30 } },
        {
          id: "mock-fast",
          type: "concrete_model",
          provider_id: "mock-fast",
          upstream_model_id: "extractor-fast",
          context_window: 8192,
        },
        {
          id: "mock-cheap",
          type: "concrete_model",
          provider_id: "mock-cheap",
          upstream_model_id: "extractor-budget",
          context_window: 8192,
        },
      ],
    },
    stream_policy: { mode: "full_buffer", rules: [{ id: "json-validity", action: "block_final" }] },
  },
];

export const modelSummaries: SyntheticModelSummary[] = models.map((model, index) => ({
  id: model.id,
  public_model_id: model.public_namespace === "prefixed" ? `ingary/${model.id}` : model.id,
  active_version: model.active_version,
  route_type: model.route_graph.nodes.find((node) => node.id === model.route_graph.root)?.type ?? "alias",
  status: index === 2 ? "staged" : "active",
  traffic_24h: [18420, 3280, 914][index],
  fallback_rate: [0.041, 0.128, 0.008][index],
  stream_trigger_count_24h: [27, 11, 3][index],
}));

export const providers: Provider[] = [
  {
    id: "local",
    kind: "openai_compatible",
    base_url: "http://127.0.0.1:11434/v1",
    credential_owner: "provider",
    health: "healthy",
  },
  {
    id: "managed",
    kind: "litellm",
    base_url: "https://gateway.example.com/v1",
    credential_owner: "ingary",
    health: "degraded",
  },
  {
    id: "mock-fast",
    kind: "mock",
    base_url: "memory://mock-fast",
    credential_owner: "provider",
    health: "healthy",
  },
  {
    id: "mock-cheap",
    kind: "mock",
    base_url: "memory://mock-cheap",
    credential_owner: "provider",
    health: "healthy",
  },
];

export const receipts: Receipt[] = [
  {
    receipt_schema: "v1",
    receipt_id: "rcpt_01hx_coding_001",
    run_id: "run-782",
    synthetic_model: "coding-balanced",
    synthetic_version: "2026-05-13.a",
    caller: {
      tenant_id: { value: "tenant-alpha", source: "trusted_auth" },
      application_id: { value: "code-review", source: "header" },
      consuming_agent_id: { value: "agent-codex", source: "header" },
      consuming_user_id: { value: "user-platform", source: "body_metadata" },
      session_id: { value: "sess-8841", source: "header" },
      run_id: { value: "run-782", source: "header" },
      tags: ["review", "typescript"],
    },
    request: { prompt_tokens_estimate: 14120, stream: true },
    decision: {
      selected_model: "local/qwen-coder",
      selected_node: "local-qwen-coder",
      skipped: [{ node: "managed-kimi", reason: "smaller_context_target_fit" }],
    },
    attempts: [{ provider_id: "local", upstream_model_id: "qwen-coder", status: "ok", latency_ms: 1834 }],
    final: { status: "ok", output_released: true, total_tokens: 18902, estimated_cost_usd: 0.0 },
  },
  {
    receipt_schema: "v1",
    receipt_id: "rcpt_01hx_coding_002",
    run_id: "run-790",
    synthetic_model: "coding-balanced",
    synthetic_version: "2026-05-13.a",
    caller: {
      tenant_id: { value: "tenant-alpha", source: "trusted_auth" },
      application_id: { value: "docs-bot", source: "header" },
      consuming_agent_id: { value: "agent-docs", source: "header" },
      consuming_user_id: { value: "anonymous", source: "derived_anonymous" },
      session_id: { value: "sess-8912", source: "body_metadata" },
      run_id: { value: "run-790", source: "header" },
    },
    request: { prompt_tokens_estimate: 88200, stream: true },
    decision: {
      selected_model: "managed/kimi-k2.6",
      selected_node: "managed-kimi",
      skipped: [{ node: "local-qwen-coder", reason: "context_window_exceeded" }],
    },
    attempts: [{ provider_id: "managed", upstream_model_id: "kimi-k2.6", status: "ok", latency_ms: 4217 }],
    final: { status: "ok", output_released: true, stream_trigger_count: 1, total_tokens: 97241, estimated_cost_usd: 0.41 },
  },
  {
    receipt_schema: "v1",
    receipt_id: "rcpt_01hx_private_001",
    run_id: "run-802",
    synthetic_model: "local-first-private",
    synthetic_version: "2026-05-08.b",
    caller: {
      tenant_id: { value: "tenant-beta", source: "trusted_auth" },
      application_id: { value: "support-agent", source: "header" },
      consuming_agent_id: { value: "agent-support", source: "header" },
      consuming_user_id: { value: "user-support", source: "header" },
      session_id: { value: "sess-9001", source: "header" },
      run_id: { value: "run-802", source: "header" },
    },
    request: { prompt_tokens_estimate: 38200, stream: false },
    decision: {
      selected_model: "managed/safe-large",
      selected_node: "managed-safe",
      skipped: [{ node: "local-small", reason: "provider_timeout" }],
    },
    attempts: [
      { provider_id: "local", upstream_model_id: "llama-local", status: "timeout", latency_ms: 5000 },
      { provider_id: "managed", upstream_model_id: "safe-large", status: "blocked", latency_ms: 2109 },
    ],
    final: { status: "blocked", output_released: false, stream_trigger_count: 2, reason: "pii-final" },
  },
];

export const receiptSummaries: ReceiptSummary[] = receipts.map((receipt) => ({
  receipt_id: receipt.receipt_id,
  synthetic_model: receipt.synthetic_model,
  synthetic_version: receipt.synthetic_version,
  selected_model: String(receipt.decision.selected_model ?? ""),
  status: String(receipt.final.status ?? "unknown"),
  stream_trigger_count: Number(receipt.final.stream_trigger_count ?? 0),
  caller: receipt.caller,
}));

export function simulateWithMocks(request: SimulationRequest): SimulationResult {
  const requestedModel = request.model ?? request.request.model;
  const model = models.find((candidate) => candidate.id === requestedModel || `ingary/${candidate.id}` === requestedModel) ?? models[0];
  const prompt = request.request.messages.map((message) => String(message.content ?? "")).join(" ");
  const estimatedTokens = Math.max(400, Math.ceil(prompt.length / 4));
  const concreteNodes = model.route_graph.nodes.filter((node) => node.type === "concrete_model");
  const selected =
    concreteNodes.find((node) => typeof node.context_window === "number" && estimatedTokens < node.context_window) ??
    concreteNodes[concreteNodes.length - 1];

  return {
    receipt: {
      receipt_schema: "v1",
      receipt_id: "simulated_receipt",
      synthetic_model: model.id,
      synthetic_version: model.active_version,
      caller: {
        consuming_agent_id: { value: String(request.request.metadata?.agent_id ?? "agent-preview"), source: "body_metadata" },
        consuming_user_id: { value: String(request.request.metadata?.user_id ?? "user-preview"), source: "body_metadata" },
        session_id: { value: "sim-session", source: "derived_anonymous" },
      },
      request: { prompt_tokens_estimate: estimatedTokens, stream: request.request.stream ?? false },
      decision: {
        selected_model: `${selected?.provider_id}/${selected?.upstream_model_id}`,
        selected_node: selected?.id,
        skipped: concreteNodes
          .filter((node) => node.id !== selected?.id)
          .map((node) => ({
            node: node.id,
            reason: estimatedTokens > Number(node.context_window ?? 0) ? "context_window_exceeded" : "lower_priority",
          })),
      },
      attempts: [{ provider_id: selected?.provider_id, upstream_model_id: selected?.upstream_model_id, status: "planned" }],
      final: { status: "simulated", output_released: false, estimated_tokens: estimatedTokens },
    },
  };
}
