use std::{
    collections::HashMap,
    future::Future,
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use tokio::sync::RwLock;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing_subscriber::{EnvFilter, fmt};
use uuid::Uuid;

const SYNTHETIC_MODEL_ID: &str = "coding-balanced";
const SYNTHETIC_VERSION: &str = "2026-05-13.mock";
const LOCAL_MODEL: &str = "local/qwen-coder";
const MANAGED_MODEL: &str = "managed/kimi-k2.6";
const LOCAL_CONTEXT_WINDOW: u64 = 32_768;
const MANAGED_CONTEXT_WINDOW: u64 = 262_144;
const SYNTHETIC_PREFIX: &str = "ingary/";

#[tokio::main]
async fn main() {
    fmt()
        .with_env_filter(
            EnvFilter::from_default_env().add_directive("rust_ingary=info".parse().unwrap()),
        )
        .init();

    let bind = std::env::var("INGARY_BIND").unwrap_or_else(|_| "127.0.0.1:8787".to_string());
    let addr: SocketAddr = bind.parse().expect("INGARY_BIND must be host:port");

    let app = app(AppState::default());
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind mock server");

    tracing::info!(%addr, "rust-ingary mock server listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("serve mock server");
}

fn app(state: AppState) -> Router {
    Router::new()
        .route("/v1/models", get(list_models))
        .route("/v1/chat/completions", post(chat_completions))
        .route("/v1/synthetic/models", get(list_synthetic_model_summaries))
        .route("/v1/synthetic/simulate", post(simulate))
        .route("/v1/receipts", get(list_receipts))
        .route("/v1/receipts/:receipt_id", get(get_receipt))
        .route("/admin/providers", get(list_providers))
        .route("/admin/storage", get(storage_health))
        .route("/admin/synthetic-models", get(list_synthetic_models))
        .route("/__test/config", post(update_test_config))
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
        .with_state(state)
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[derive(Clone)]
struct AppState {
    receipt_store: Arc<dyn ReceiptStore>,
    config: Arc<RwLock<TestConfig>>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            receipt_store: Arc::new(MemoryReceiptStore::default()),
            config: Arc::new(RwLock::new(TestConfig::default())),
        }
    }
}

type StoreFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

trait ReceiptStore: Send + Sync {
    fn health<'a>(&'a self) -> StoreFuture<'a, Value>;

    fn insert_receipt<'a>(&'a self, receipt: Receipt) -> StoreFuture<'a, ()>;

    fn get_receipt<'a>(&'a self, receipt_id: &'a str) -> StoreFuture<'a, Option<Receipt>>;

    fn clear_receipts<'a>(&'a self) -> StoreFuture<'a, ()>;

    fn list_receipts<'a>(
        &'a self,
        query: &'a ReceiptQuery,
        limit: usize,
    ) -> StoreFuture<'a, Vec<ReceiptSummary>>;
}

#[derive(Default)]
struct MemoryReceiptStore {
    receipts: RwLock<Vec<Receipt>>,
}

impl ReceiptStore for MemoryReceiptStore {
    fn health<'a>(&'a self) -> StoreFuture<'a, Value> {
        Box::pin(async move {
            json!({
                "kind": "memory",
                "contract_version": "storage-contract-v0",
                "migration_version": 1,
                "read_health": "ok",
                "write_health": "ok",
                "capabilities": {
                    "durable": false,
                    "transactional": true,
                    "concurrent_writers": false,
                    "json_queries": true,
                    "event_replay": true,
                    "time_range_indexes": false,
                    "retention_jobs": false
                }
            })
        })
    }

    fn insert_receipt<'a>(&'a self, receipt: Receipt) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.receipts.write().await.push(receipt);
        })
    }

    fn get_receipt<'a>(&'a self, receipt_id: &'a str) -> StoreFuture<'a, Option<Receipt>> {
        Box::pin(async move {
            self.receipts
                .read()
                .await
                .iter()
                .find(|receipt| receipt.receipt_id == receipt_id)
                .cloned()
        })
    }

    fn clear_receipts<'a>(&'a self) -> StoreFuture<'a, ()> {
        Box::pin(async move {
            self.receipts.write().await.clear();
        })
    }

    fn list_receipts<'a>(
        &'a self,
        query: &'a ReceiptQuery,
        limit: usize,
    ) -> StoreFuture<'a, Vec<ReceiptSummary>> {
        Box::pin(async move {
            self.receipts
                .read()
                .await
                .iter()
                .rev()
                .filter(|receipt| query.matches(receipt))
                .take(limit)
                .map(ReceiptSummary::from)
                .collect()
        })
    }
}

async fn list_models(State(state): State<AppState>) -> Json<Value> {
    let cfg = state.config.read().await.clone();
    Json(json!({
        "object": "list",
        "data": [
            {"id": cfg.synthetic_model, "object": "model", "owned_by": "ingary"},
            {"id": format!("{SYNTHETIC_PREFIX}{}", cfg.synthetic_model), "object": "model", "owned_by": "ingary"}
        ]
    }))
}

async fn list_synthetic_model_summaries(State(state): State<AppState>) -> Json<Value> {
    let cfg = state.config.read().await.clone();
    Json(json!({ "data": [synthetic_model_record(&cfg)] }))
}

async fn chat_completions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<ChatCompletionRequest>,
) -> Result<Response, ApiError> {
    let cfg = state.config.read().await.clone();
    let normalized_model = normalize_model(request.model.as_deref(), &cfg).ok_or_else(|| {
        ApiError::bad_request(format!(
            "model must be {} or {}{}",
            cfg.synthetic_model, SYNTHETIC_PREFIX, cfg.synthetic_model
        ))
    })?;
    let mut request = apply_prompt_transforms(request, &cfg);
    let policy = evaluate_request_policies(&mut request, &cfg);
    let caller = caller_from(headers.clone(), request.metadata.as_ref());
    let decision = select_route(&request, &cfg);
    let receipt = build_receipt(
        caller,
        normalized_model.clone(),
        Some(request.clone()),
        decision.clone(),
        "completed",
        &cfg,
        policy,
    );

    state.receipt_store.insert_receipt(receipt.clone()).await;

    let created = unix_now();
    let reply = format!(
        "Mock Ingary response via {} for {} estimated tokens.",
        decision.selected_model, decision.estimated_prompt_tokens
    );
    let response_body = json!({
        "id": format!("chatcmpl-{}", Uuid::new_v4()),
        "object": "chat.completion",
        "created": created,
        "model": format!("ingary/{normalized_model}"),
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": reply},
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": decision.estimated_prompt_tokens,
            "completion_tokens": 16,
            "total_tokens": decision.estimated_prompt_tokens + 16
        },
        "ingary": {
            "receipt_id": receipt.receipt_id,
            "selected_model": decision.selected_model
        }
    });

    let mut response = Json(response_body).into_response();
    response.headers_mut().insert(
        "X-Ingary-Receipt-Id",
        HeaderValue::from_str(&receipt.receipt_id).map_err(|_| ApiError::internal())?,
    );
    response.headers_mut().insert(
        "X-Ingary-Selected-Model",
        HeaderValue::from_str(&decision.selected_model).map_err(|_| ApiError::internal())?,
    );
    Ok(response)
}

async fn simulate(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(mut request): Json<SimulationRequest>,
) -> Result<Json<Value>, ApiError> {
    let model = request
        .model
        .as_deref()
        .or(request.request.model.as_deref());
    let cfg = state.config.read().await.clone();
    let normalized_model = normalize_model(model, &cfg).ok_or_else(|| {
        ApiError::bad_request(format!(
            "model must be {} or {}{}",
            cfg.synthetic_model, SYNTHETIC_PREFIX, cfg.synthetic_model
        ))
    })?;
    request.request = apply_prompt_transforms(request.request, &cfg);
    let policy = evaluate_request_policies(&mut request.request, &cfg);
    let caller = caller_from(headers, request.request.metadata.as_ref());
    let decision = select_route(&request.request, &cfg);
    let receipt = build_receipt(
        caller,
        normalized_model,
        Some(request.request),
        decision,
        "simulated",
        &cfg,
        policy,
    );

    state.receipt_store.insert_receipt(receipt.clone()).await;
    Ok(Json(json!({ "receipt": receipt })))
}

async fn list_receipts(
    State(state): State<AppState>,
    Query(query): Query<ReceiptQuery>,
) -> Json<Value> {
    let limit = query.limit.unwrap_or(50).clamp(1, 500);
    let data = state.receipt_store.list_receipts(&query, limit).await;

    Json(json!({ "data": data }))
}

async fn get_receipt(
    State(state): State<AppState>,
    Path(receipt_id): Path<String>,
) -> Result<Json<Receipt>, ApiError> {
    state
        .receipt_store
        .get_receipt(&receipt_id)
        .await
        .map(Json)
        .ok_or_else(|| ApiError::not_found("receipt not found"))
}

async fn list_providers() -> Json<Value> {
    Json(json!({
        "data": [
            {
                "id": "local",
                "kind": "mock",
                "base_url": "mock://local",
                "credential_owner": "ingary",
                "health": "healthy"
            },
            {
                "id": "managed",
                "kind": "mock",
                "base_url": "mock://managed",
                "credential_owner": "ingary",
                "health": "healthy"
            }
        ]
    }))
}

async fn storage_health(State(state): State<AppState>) -> Json<Value> {
    Json(state.receipt_store.health().await)
}

async fn list_synthetic_models(State(state): State<AppState>) -> Json<Value> {
    let cfg = state.config.read().await.clone();
    Json(json!({ "data": [synthetic_model_record(&cfg)] }))
}

async fn update_test_config(
    State(state): State<AppState>,
    Json(mut cfg): Json<TestConfig>,
) -> Result<Json<Value>, ApiError> {
    cfg.normalize();
    cfg.validate().map_err(ApiError::bad_request)?;
    state.receipt_store.clear_receipts().await;
    *state.config.write().await = cfg.clone();
    Ok(Json(json!({
        "status": "ok",
        "synthetic_model": cfg.synthetic_model,
        "targets": cfg.targets
    })))
}

fn synthetic_model_record(cfg: &TestConfig) -> Value {
    let mut targets = cfg.targets.clone();
    targets.sort_by(|left, right| {
        left.context_window
            .cmp(&right.context_window)
            .then_with(|| left.model.cmp(&right.model))
    });
    let target_ids: Vec<String> = targets
        .iter()
        .map(|target| target.model.replace('/', "."))
        .collect();
    let mut nodes = vec![json!({
        "id": "dispatcher.prompt_length",
        "type": "dispatcher",
        "targets": target_ids,
        "strategy": "estimated_prompt_length"
    })];
    for target in targets {
        nodes.push(json!({
            "id": target.model.replace('/', "."),
            "type": "concrete_model",
            "provider_id": target.model.split('/').next().unwrap_or("mock"),
            "upstream_model_id": target.model,
            "context_window": target.context_window
        }));
    }
    json!({
        "id": cfg.synthetic_model,
        "public_model_id": cfg.synthetic_model,
        "active_version": cfg.version,
        "description": "Mock dispatcher that selects a local coding model for short prompts and a managed long-context model for larger prompts.",
        "public_namespace": "flat",
        "route_type": "dispatcher",
        "status": "active",
        "traffic_24h": 0,
        "fallback_rate": 0.0,
        "stream_trigger_count_24h": 0,
        "route_graph": {
            "root": "dispatcher.prompt_length",
            "nodes": nodes
        },
        "stream_policy": {
            "mode": "buffered_horizon",
            "buffer_tokens": 256,
            "rules": cfg.stream_rules
        },
        "prompt_transforms": cfg.prompt_transforms,
        "structured_output": cfg.structured_output,
        "governance": cfg.governance
    })
}

fn normalize_model(model: Option<&str>, cfg: &TestConfig) -> Option<String> {
    let model = model?
        .trim()
        .strip_prefix(SYNTHETIC_PREFIX)
        .unwrap_or(model?.trim());
    if model == cfg.synthetic_model {
        Some(cfg.synthetic_model.clone())
    } else {
        None
    }
}

fn select_route(request: &ChatCompletionRequest, cfg: &TestConfig) -> RouteDecision {
    let estimated_prompt_tokens = estimate_prompt_tokens(&request.messages);
    let mut targets = cfg.targets.clone();
    targets.sort_by(|left, right| {
        left.context_window
            .cmp(&right.context_window)
            .then_with(|| left.model.cmp(&right.model))
    });
    let mut skipped = Vec::new();
    let mut selected_model = targets
        .last()
        .map(|target| target.model.clone())
        .unwrap_or_else(|| "unconfigured/no-target".to_string());
    for target in targets {
        if target.context_window >= estimated_prompt_tokens {
            selected_model = target.model;
            break;
        }
        skipped.push(json!({
            "target": target.model,
            "reason": "context_window_too_small",
            "context_window": target.context_window
        }));
    }

    RouteDecision {
        selected_model,
        estimated_prompt_tokens,
        reason: if skipped.is_empty() {
            "estimated prompt fits selected context window".to_string()
        } else {
            "estimated prompt exceeded smaller configured context windows".to_string()
        },
        skipped,
    }
}

fn apply_prompt_transforms(
    mut request: ChatCompletionRequest,
    cfg: &TestConfig,
) -> ChatCompletionRequest {
    if let Some(preamble) = cfg
        .prompt_transforms
        .as_ref()
        .and_then(|transforms| nonblank(transforms.preamble.as_deref()))
    {
        request.messages.insert(
            0,
            ChatMessage {
                role: "system".to_string(),
                content: Value::String(preamble.to_string()),
                name: Some("ingary_preamble".to_string()),
                extra: HashMap::new(),
            },
        );
    }
    if let Some(postscript) = cfg
        .prompt_transforms
        .as_ref()
        .and_then(|transforms| nonblank(transforms.postscript.as_deref()))
    {
        request.messages.push(ChatMessage {
            role: "system".to_string(),
            content: Value::String(postscript.to_string()),
            name: Some("ingary_postscript".to_string()),
            extra: HashMap::new(),
        });
    }
    request
}

#[derive(Debug, Clone, Default)]
struct PolicyResult {
    actions: Vec<Value>,
    events: Vec<Value>,
    alert_count: u64,
}

fn evaluate_request_policies(
    request: &mut ChatCompletionRequest,
    cfg: &TestConfig,
) -> PolicyResult {
    let mut result = PolicyResult::default();
    let text = request_text(&request.messages).to_lowercase();
    for rule in &cfg.governance {
        let kind = rule.get("kind").and_then(Value::as_str).unwrap_or_default();
        if !matches!(
            kind,
            "request_guard" | "request_transform" | "receipt_annotation"
        ) {
            continue;
        }
        let contains = rule
            .get("contains")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty());
        let Some(contains) = contains else { continue };
        if !text.contains(&contains.to_lowercase()) {
            continue;
        }
        let rule_id = rule.get("id").and_then(Value::as_str).unwrap_or("policy");
        let action = rule
            .get("action")
            .and_then(Value::as_str)
            .unwrap_or("annotate");
        let message = rule
            .get("message")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or("request policy matched");
        let severity = rule
            .get("severity")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or("info");
        let mut action_record = json!({
            "rule_id": rule_id,
            "kind": kind,
            "action": action,
            "matched": true,
            "message": message,
            "severity": severity
        });
        match action {
            "escalate" => {
                result.alert_count += 1;
                result.events.push(json!({
                    "type": "policy.alert",
                    "rule_id": rule_id,
                    "message": message,
                    "severity": severity
                }));
            }
            "inject_reminder_and_retry" | "transform" => {
                let reminder = rule
                    .get("reminder")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or(message);
                request.messages.push(ChatMessage {
                    role: "system".to_string(),
                    content: Value::String(reminder.to_string()),
                    name: Some("ingary_policy_reminder".to_string()),
                    extra: HashMap::new(),
                });
                if let Value::Object(ref mut object) = action_record {
                    object.insert("reminder_injected".to_string(), Value::Bool(true));
                }
            }
            "annotate" => {
                result.events.push(json!({
                    "type": "policy.annotated",
                    "rule_id": rule_id,
                    "message": message,
                    "severity": severity
                }));
            }
            _ => {}
        }
        result.actions.push(action_record);
    }
    result
}

fn request_text(messages: &[ChatMessage]) -> String {
    let mut text = String::new();
    for message in messages {
        text.push_str(&message.role);
        text.push('\n');
        match &message.content {
            Value::String(value) => text.push_str(value),
            Value::Null => {}
            other => text.push_str(&other.to_string()),
        }
        text.push('\n');
    }
    text
}

fn nonblank(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn estimate_prompt_tokens(messages: &[ChatMessage]) -> u64 {
    let chars: usize = messages.iter().map(ChatMessage::content_len).sum();
    let role_overhead = messages.len() * 4;
    ((chars + role_overhead).max(1) as u64).div_ceil(4)
}

fn build_receipt(
    caller: CallerContext,
    synthetic_model: String,
    request: Option<ChatCompletionRequest>,
    decision: RouteDecision,
    status: &str,
    cfg: &TestConfig,
    policy: PolicyResult,
) -> Receipt {
    let receipt_id = format!("rcpt_{}", Uuid::new_v4());
    let run_id = caller.run_id.as_ref().map(|run_id| run_id.value.clone());
    Receipt {
        receipt_schema: "v1".to_string(),
        receipt_id,
        run_id,
        synthetic_model,
        synthetic_version: cfg.version.clone(),
        caller,
        request: request.map(|request| {
            let mut value = serde_json::to_value(request).unwrap_or(Value::Null);
            if let Value::Object(ref mut object) = value {
                object.insert(
                    "prompt_transforms".to_string(),
                    serde_json::to_value(&cfg.prompt_transforms).unwrap_or(Value::Null),
                );
                object.insert(
                    "structured_output".to_string(),
                    cfg.structured_output.clone().unwrap_or(Value::Null),
                );
            }
            value
        }),
        decision: json!({
            "strategy": "estimated_prompt_length",
            "estimated_prompt_tokens": decision.estimated_prompt_tokens,
            "selected_model": decision.selected_model,
            "selected_provider": decision.selected_model.split('/').next().unwrap_or("mock"),
            "skipped": decision.skipped,
            "reason": decision.reason,
            "rule": "select the smallest configured context window that fits the estimated prompt",
            "governance": cfg.governance,
            "policy_actions": policy.actions
        }),
        attempts: vec![json!({
            "provider_id": decision.selected_model.split('/').next().unwrap_or("mock"),
            "model": decision.selected_model,
            "status": status,
            "mock": true,
            "called_provider": status != "simulated"
        })],
        final_result: json!({
            "status": status,
            "selected_model": decision.selected_model,
            "stream_trigger_count": 0,
            "alert_count": policy.alert_count,
            "events": policy.events
        }),
    }
}

fn caller_from(headers: HeaderMap, metadata: Option<&Map<String, Value>>) -> CallerContext {
    CallerContext {
        tenant_id: sourced("X-Ingary-Tenant-Id", "tenant_id", &headers, metadata),
        application_id: sourced(
            "X-Ingary-Application-Id",
            "application_id",
            &headers,
            metadata,
        ),
        consuming_agent_id: sourced(
            "X-Ingary-Agent-Id",
            "consuming_agent_id",
            &headers,
            metadata,
        )
        .or_else(|| sourced("X-Ingary-Agent-Id", "agent_id", &headers, metadata)),
        consuming_user_id: sourced("X-Ingary-User-Id", "consuming_user_id", &headers, metadata)
            .or_else(|| sourced("X-Ingary-User-Id", "user_id", &headers, metadata)),
        session_id: sourced("X-Ingary-Session-Id", "session_id", &headers, metadata),
        run_id: sourced("X-Ingary-Run-Id", "run_id", &headers, metadata),
        tags: metadata
            .and_then(|metadata| metadata.get("tags"))
            .and_then(Value::as_array)
            .map(|tags| {
                tags.iter()
                    .filter_map(Value::as_str)
                    .map(ToOwned::to_owned)
                    .collect()
            })
            .unwrap_or_default(),
    }
}

fn sourced(
    header_name: &'static str,
    metadata_key: &'static str,
    headers: &HeaderMap,
    metadata: Option<&Map<String, Value>>,
) -> Option<SourcedString> {
    headers
        .get(header_name)
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .map(|value| SourcedString {
            value: value.to_string(),
            source: "header".to_string(),
        })
        .or_else(|| {
            metadata
                .and_then(|metadata| metadata.get(metadata_key))
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(|value| SourcedString {
                    value: value.to_string(),
                    source: "body_metadata".to_string(),
                })
        })
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct ChatCompletionRequest {
    model: Option<String>,
    #[serde(default)]
    messages: Vec<ChatMessage>,
    #[serde(default)]
    stream: bool,
    #[serde(default)]
    metadata: Option<Map<String, Value>>,
    #[serde(flatten)]
    extra: HashMap<String, Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct ChatMessage {
    role: String,
    #[serde(default)]
    content: Value,
    #[serde(default)]
    name: Option<String>,
    #[serde(flatten)]
    extra: HashMap<String, Value>,
}

impl ChatMessage {
    fn content_len(&self) -> usize {
        match &self.content {
            Value::String(value) => value.chars().count(),
            Value::Array(parts) => parts
                .iter()
                .map(|part| {
                    part.get("text")
                        .and_then(Value::as_str)
                        .or_else(|| part.get("content").and_then(Value::as_str))
                        .map(str::len)
                        .unwrap_or_else(|| part.to_string().len())
                })
                .sum(),
            Value::Null => 0,
            other => other.to_string().len(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct SimulationRequest {
    model: Option<String>,
    request: ChatCompletionRequest,
}

#[derive(Debug, Clone)]
struct RouteDecision {
    selected_model: String,
    estimated_prompt_tokens: u64,
    skipped: Vec<Value>,
    reason: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct TestConfig {
    synthetic_model: String,
    #[serde(default)]
    version: String,
    targets: Vec<RouteTarget>,
    #[serde(default)]
    stream_rules: Vec<StreamRule>,
    #[serde(default)]
    prompt_transforms: Option<PromptTransforms>,
    #[serde(default)]
    structured_output: Option<Value>,
    #[serde(default)]
    governance: Vec<Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct RouteTarget {
    model: String,
    context_window: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct StreamRule {
    id: Option<String>,
    pattern: Option<String>,
    action: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct PromptTransforms {
    preamble: Option<String>,
    postscript: Option<String>,
}

impl Default for TestConfig {
    fn default() -> Self {
        Self {
            synthetic_model: SYNTHETIC_MODEL_ID.to_string(),
            version: SYNTHETIC_VERSION.to_string(),
            targets: vec![
                RouteTarget {
                    model: LOCAL_MODEL.to_string(),
                    context_window: LOCAL_CONTEXT_WINDOW,
                },
                RouteTarget {
                    model: MANAGED_MODEL.to_string(),
                    context_window: MANAGED_CONTEXT_WINDOW,
                },
            ],
            stream_rules: vec![StreamRule {
                id: Some("mock_noop".to_string()),
                pattern: Some("".to_string()),
                action: "pass".to_string(),
            }],
            prompt_transforms: None,
            structured_output: None,
            governance: vec![json!({
                "id": "prompt_transforms",
                "kind": "request_transform",
                "action": "transform"
            })],
        }
    }
}

impl TestConfig {
    fn normalize(&mut self) {
        if self.version.trim().is_empty() {
            self.version = SYNTHETIC_VERSION.to_string();
        }
        self.synthetic_model = self.synthetic_model.trim().to_string();
        for target in &mut self.targets {
            target.model = target.model.trim().to_string();
        }
    }

    fn validate(&self) -> Result<(), String> {
        if self.synthetic_model.is_empty() {
            return Err("synthetic_model must not be empty".to_string());
        }
        if self.synthetic_model.contains('/') {
            return Err("synthetic_model must be unprefixed".to_string());
        }
        if self.targets.is_empty() {
            return Err("targets must not be empty".to_string());
        }
        let mut seen = std::collections::HashSet::new();
        for target in &self.targets {
            if target.model.is_empty() {
                return Err("target model must not be empty".to_string());
            }
            if target.context_window == 0 {
                return Err(format!(
                    "target {} context_window must be positive",
                    target.model
                ));
            }
            if !seen.insert(target.model.as_str()) {
                return Err(format!("duplicate target {}", target.model));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct SourcedString {
    value: String,
    source: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct CallerContext {
    #[serde(skip_serializing_if = "Option::is_none")]
    tenant_id: Option<SourcedString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    application_id: Option<SourcedString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    consuming_agent_id: Option<SourcedString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    consuming_user_id: Option<SourcedString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<SourcedString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    run_id: Option<SourcedString>,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct Receipt {
    receipt_schema: String,
    receipt_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    run_id: Option<String>,
    synthetic_model: String,
    synthetic_version: String,
    caller: CallerContext,
    #[serde(skip_serializing_if = "Option::is_none")]
    request: Option<Value>,
    decision: Value,
    attempts: Vec<Value>,
    #[serde(rename = "final")]
    final_result: Value,
}

#[derive(Debug, Serialize)]
struct ReceiptSummary {
    receipt_id: String,
    synthetic_model: String,
    synthetic_version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    selected_model: Option<String>,
    status: String,
    stream_trigger_count: u64,
    caller: CallerContext,
}

impl From<&Receipt> for ReceiptSummary {
    fn from(receipt: &Receipt) -> Self {
        Self {
            receipt_id: receipt.receipt_id.clone(),
            synthetic_model: receipt.synthetic_model.clone(),
            synthetic_version: receipt.synthetic_version.clone(),
            selected_model: receipt
                .decision
                .get("selected_model")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            status: receipt
                .final_result
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
            stream_trigger_count: receipt
                .final_result
                .get("stream_trigger_count")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            caller: receipt.caller.clone(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct ReceiptQuery {
    model: Option<String>,
    consuming_agent_id: Option<String>,
    consuming_user_id: Option<String>,
    session_id: Option<String>,
    run_id: Option<String>,
    status: Option<String>,
    limit: Option<usize>,
}

impl ReceiptQuery {
    fn matches(&self, receipt: &Receipt) -> bool {
        self.model.as_deref().is_none_or(|model| {
            normalize_model_filter(model).as_deref() == Some(&receipt.synthetic_model)
        }) && self
            .consuming_agent_id
            .as_deref()
            .is_none_or(|value| sourced_value(&receipt.caller.consuming_agent_id) == Some(value))
            && self
                .consuming_user_id
                .as_deref()
                .is_none_or(|value| sourced_value(&receipt.caller.consuming_user_id) == Some(value))
            && self
                .session_id
                .as_deref()
                .is_none_or(|value| sourced_value(&receipt.caller.session_id) == Some(value))
            && self
                .run_id
                .as_deref()
                .is_none_or(|value| receipt.run_id.as_deref() == Some(value))
            && self.status.as_deref().is_none_or(|status| {
                receipt.final_result.get("status").and_then(Value::as_str) == Some(status)
            })
    }
}

fn sourced_value(value: &Option<SourcedString>) -> Option<&str> {
    value.as_ref().map(|value| value.value.as_str())
}

fn normalize_model_filter(model: &str) -> Option<String> {
    let model = model
        .trim()
        .strip_prefix(SYNTHETIC_PREFIX)
        .unwrap_or(model.trim());
    if model.is_empty() {
        None
    } else {
        Some(model.to_string())
    }
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
    error_type: &'static str,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
            error_type: "invalid_request_error",
        }
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: message.into(),
            error_type: "not_found_error",
        }
    }

    fn internal() -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: "internal server error".to_string(),
            error_type: "internal_error",
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = Json(json!({
            "error": {
                "message": self.message,
                "type": self.error_type
            }
        }));
        (self.status, body).into_response()
    }
}
