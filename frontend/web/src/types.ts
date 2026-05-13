export type NodeType =
  | "alias"
  | "dispatcher"
  | "cascade"
  | "alloy"
  | "guard"
  | "concrete_model";

export type Source =
  | "trusted_auth"
  | "header"
  | "body_metadata"
  | "provider_key"
  | "derived_anonymous";

export type SourcedString = {
  value: string;
  source: Source;
};

export type CallerContext = {
  tenant_id?: SourcedString;
  application_id?: SourcedString;
  consuming_agent_id?: SourcedString;
  consuming_user_id?: SourcedString;
  session_id?: SourcedString;
  run_id?: SourcedString;
  tags?: string[];
};

export type SyntheticModelSummary = {
  id: string;
  public_model_id?: string;
  active_version: string;
  route_type: string;
  status: string;
  traffic_24h?: number;
  fallback_rate?: number;
  stream_trigger_count_24h?: number;
};

export type RouteNode = {
  id: string;
  type: NodeType;
  targets?: string[];
  provider_id?: string;
  upstream_model_id?: string;
  context_window?: number;
  [key: string]: unknown;
};

export type RouteGraph = {
  root: string;
  nodes: RouteNode[];
};

export type StreamPolicy = {
  mode?: "pass_through" | "buffered_horizon" | "semantic_boundary" | "full_buffer";
  buffer_tokens?: number;
  rules?: Array<Record<string, unknown>>;
};

export type SyntheticModel = {
  id: string;
  active_version: string;
  description?: string;
  public_namespace?: "flat" | "prefixed";
  route_graph: RouteGraph;
  stream_policy?: StreamPolicy;
};

export type ChatMessage = {
  role: "system" | "user" | "assistant" | "tool" | "developer";
  content?: string | null | Array<Record<string, unknown>>;
  name?: string;
  [key: string]: unknown;
};

export type ChatCompletionRequest = {
  model: string;
  messages: ChatMessage[];
  stream?: boolean;
  metadata?: Record<string, unknown>;
  [key: string]: unknown;
};

export type SimulationRequest = {
  model?: string;
  request: ChatCompletionRequest;
};

export type ReceiptSummary = {
  receipt_id: string;
  synthetic_model: string;
  synthetic_version: string;
  selected_model?: string;
  status: string;
  stream_trigger_count?: number;
  caller: CallerContext;
};

export type Receipt = {
  receipt_schema: "v1";
  receipt_id: string;
  run_id?: string;
  synthetic_model: string;
  synthetic_version: string;
  caller: CallerContext;
  request?: Record<string, unknown>;
  decision: Record<string, unknown>;
  attempts: Array<Record<string, unknown>>;
  persistence?: ReceiptPersistence;
  final: Record<string, unknown>;
};

export type SimulationResult = {
  receipt: Receipt;
};

export type Provider = {
  id: string;
  kind: "openai_compatible" | "litellm" | "helicone" | "openrouter" | "portkey" | "mock";
  base_url: string;
  credential_owner: "provider" | "ingary";
  health?: string;
};

export type StorageProvider = {
  id: string;
  kind: "memory" | "sqlite" | "postgres" | "duckdb";
  role: "system_of_record" | "analytics_export" | "ephemeral";
  status: "healthy" | "degraded" | "stale" | "offline";
  contract_version: string;
  migration_version: string;
  failure_policy: "fail_closed" | "degrade_open" | "read_only";
  retention_days?: number;
  receipt_count: number;
  event_count: number;
  capabilities: string[];
};

export type Sink = {
  id: string;
  kind: "search" | "event_stream" | "log" | "metrics";
  target: string;
  status: "healthy" | "degraded" | "stale" | "offline";
  derived_from: string;
  delivery: "sync" | "async";
  lag_ms?: number;
  backlog?: number;
  redaction: "receipt_summary" | "event_metadata" | "metrics_only";
  failure_policy: "queue" | "drop" | "backpressure";
  indexed_receipts?: number;
};

export type ReceiptPersistence = {
  storage_provider_id: string;
  stored: boolean;
  event_count: number;
  sink_projection_status: "projected" | "pending" | "stale" | "skipped";
  projected_sink_ids: string[];
};

export type ReceiptFilters = {
  model?: string;
  consuming_agent_id?: string;
  consuming_user_id?: string;
  session_id?: string;
  run_id?: string;
  status?: string;
  limit?: number;
};
