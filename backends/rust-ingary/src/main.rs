use std::{
    collections::HashMap,
    future::Future,
    net::SocketAddr,
    pin::Pin,
    process::Command,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    Json, Router,
    body::Body,
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
        .route("/v1/policy-cache/events", post(add_policy_cache_event))
        .route("/v1/policy-cache/recent", get(list_policy_cache_recent))
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
    policy_cache: Arc<Mutex<MemoryPolicyCache>>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            receipt_store: Arc::new(MemoryReceiptStore::default()),
            config: Arc::new(RwLock::new(TestConfig::default())),
            policy_cache: Arc::new(Mutex::new(MemoryPolicyCache::new(
                TestConfig::default().policy_cache,
            ))),
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
    Json(raw_request): Json<Value>,
) -> Result<Response, ApiError> {
    let request = ChatCompletionRequest::from_value(raw_request);
    let cfg = state.config.read().await.clone();
    let normalized_model = normalize_model(request.model.as_deref(), &cfg).ok_or_else(|| {
        ApiError::bad_request(format!(
            "model must be {} or {}{}",
            cfg.synthetic_model, SYNTHETIC_PREFIX, cfg.synthetic_model
        ))
    })?;
    let caller = caller_from(headers.clone(), request.metadata_map());
    let mut request = apply_prompt_transforms(request, &cfg);
    let policy = {
        let cache = state
            .policy_cache
            .lock()
            .map_err(|_| ApiError::internal())?;
        evaluate_request_policies_with_cache(&mut request, &cfg, &caller, Some(&cache))
    };
    let wants_stream = request.stream;
    let decision = select_route(&request, &cfg);
    let provider = complete_selected_model(&decision.selected_model, &request, &cfg).await;
    let mut reply = completion_text(&provider, &decision);
    let mut stream_governance = evaluate_stream_governance(&reply, &cfg, true);
    let mut retry_provider = None;
    if let Some(retry) = stream_governance.retry.clone() {
        let mut retry_request = request.clone();
        retry_request.messages.push(ChatMessage {
            role: "system".to_string(),
            content: Value::String(retry.reminder),
            name: Some("ingary_stream_policy_reminder".to_string()),
            extra: HashMap::new(),
        });
        let provider_retry =
            complete_selected_model(&decision.selected_model, &retry_request, &cfg).await;
        let retry_reply = completion_text(&provider_retry, &decision);
        let retry_governance = evaluate_stream_governance(&retry_reply, &cfg, false);
        stream_governance = stream_governance.with_retry_result(retry_governance);
        reply = stream_governance.content.clone();
        retry_provider = Some(provider_retry);
    } else {
        reply = stream_governance.content.clone();
    }
    let mut receipt = build_receipt(
        caller,
        normalized_model.clone(),
        Some(request.clone()),
        decision.clone(),
        provider.status.as_str(),
        &cfg,
        policy,
    );
    apply_provider_outcome(&mut receipt, &provider);
    if let Some(retry_provider) = &retry_provider {
        append_provider_attempt(&mut receipt, &decision.selected_model, retry_provider);
    }
    apply_stream_governance_to_receipt(&mut receipt, &stream_governance);

    state.receipt_store.insert_receipt(receipt.clone()).await;

    let created = unix_now();
    if wants_stream {
        return sse_chat_response(
            created,
            &normalized_model,
            &decision.selected_model,
            &receipt.receipt_id,
            &stream_governance.released_chunks,
            stream_governance.finish_reason(),
        );
    }
    let response_body = json!({
        "id": format!("chatcmpl-{}", Uuid::new_v4()),
        "object": "chat.completion",
        "created": created,
        "model": format!("ingary/{normalized_model}"),
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": reply},
            "finish_reason": stream_governance.finish_reason()
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
    let caller = caller_from(headers, request.request.metadata_map());
    request.request = apply_prompt_transforms(request.request, &cfg);
    let policy = {
        let cache = state
            .policy_cache
            .lock()
            .map_err(|_| ApiError::internal())?;
        evaluate_request_policies_with_cache(&mut request.request, &cfg, &caller, Some(&cache))
    };
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

async fn list_providers(State(state): State<AppState>) -> Json<Value> {
    let cfg = state.config.read().await.clone();
    Json(json!({ "data": providers_for_config(&cfg) }))
}

async fn storage_health(State(state): State<AppState>) -> Json<Value> {
    Json(state.receipt_store.health().await)
}

async fn add_policy_cache_event(
    State(state): State<AppState>,
    Json(input): Json<PolicyCacheEventInput>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let event = state
        .policy_cache
        .lock()
        .map_err(|_| ApiError::internal())?
        .add(input)
        .map_err(ApiError::bad_request)?;
    Ok((StatusCode::CREATED, Json(json!({ "event": event }))))
}

async fn list_policy_cache_recent(
    State(state): State<AppState>,
    Query(query): Query<PolicyCacheQuery>,
) -> Result<Json<Value>, ApiError> {
    let limit = query.limit.unwrap_or(50).clamp(1, 500);
    let filter = PolicyCacheFilter::from(query);
    let events = state
        .policy_cache
        .lock()
        .map_err(|_| ApiError::internal())?
        .recent(&filter, limit);
    Ok(Json(json!({ "data": events })))
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
    state
        .policy_cache
        .lock()
        .map_err(|_| ApiError::internal())?
        .configure(cfg.policy_cache);
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

fn providers_for_config(cfg: &TestConfig) -> Vec<Value> {
    let mut seen = std::collections::HashSet::new();
    let mut providers = Vec::new();
    for target in &cfg.targets {
        let id = target
            .model
            .split('/')
            .next()
            .unwrap_or("mock")
            .trim()
            .to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let mut kind = provider_kind(target).to_string();
        let mut base_url = target.provider_base_url.clone().unwrap_or_default();
        if base_url.trim().is_empty() {
            if id == "ollama" {
                kind = "ollama".to_string();
                base_url = std::env::var("OLLAMA_BASE_URL")
                    .unwrap_or_else(|_| "http://127.0.0.1:11434".to_string());
            } else {
                base_url = format!("mock://{id}");
            }
        }
        providers.push(json!({
            "id": id,
            "kind": kind,
            "base_url": base_url,
            "credential_owner": "ingary",
            "credential_source": credential_source(target),
            "health": "ok"
        }));
    }
    providers
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

#[derive(Debug, Clone)]
struct ProviderOutcome {
    content: Option<String>,
    status: String,
    latency_ms: u128,
    error: Option<String>,
    called_provider: bool,
    mock: bool,
}

#[derive(Debug, Clone, Default)]
struct StreamGovernanceResult {
    content: String,
    released_chunks: Vec<String>,
    trigger_count: u64,
    alert_count: u64,
    actions: Vec<Value>,
    events: Vec<Value>,
    final_status: Option<String>,
    retry: Option<StreamRetry>,
    retry_attempted: bool,
}

#[derive(Debug, Clone)]
struct StreamRetry {
    rule_id: String,
    reminder: String,
}

#[derive(Debug, Clone)]
struct StreamAttemptResult {
    content: String,
    released_chunks: Vec<String>,
    released_before_trigger: String,
    matched: Option<StreamMatch>,
}

#[derive(Debug, Clone)]
struct StreamMatch {
    rule_id: String,
    action: String,
    matcher: String,
    pattern_len_bytes: usize,
    match_offset_bytes: usize,
    released_before_trigger_bytes: usize,
    reminder: String,
    max_retries: u32,
}

async fn complete_selected_model(
    selected_model: &str,
    request: &ChatCompletionRequest,
    cfg: &TestConfig,
) -> ProviderOutcome {
    let started = std::time::Instant::now();
    let Some(target) = cfg
        .targets
        .iter()
        .find(|target| target.model == selected_model)
    else {
        return ProviderOutcome {
            content: None,
            status: "completed".to_string(),
            latency_ms: started.elapsed().as_millis(),
            error: None,
            called_provider: false,
            mock: true,
        };
    };
    let result = match provider_kind(target) {
        "mock" => {
            return ProviderOutcome {
                content: None,
                status: "completed".to_string(),
                latency_ms: started.elapsed().as_millis(),
                error: None,
                called_provider: false,
                mock: true,
            };
        }
        "ollama" => complete_with_ollama(target, request).await,
        "openai-compatible" => complete_with_openai_compatible(target, request).await,
        kind => Err(format!("unsupported provider kind {kind:?}")),
    };
    match result {
        Ok(content) => ProviderOutcome {
            content: Some(content),
            status: "completed".to_string(),
            latency_ms: started.elapsed().as_millis(),
            error: None,
            called_provider: true,
            mock: false,
        },
        Err(error) => ProviderOutcome {
            content: None,
            status: "provider_error".to_string(),
            latency_ms: started.elapsed().as_millis(),
            error: Some(error),
            called_provider: true,
            mock: false,
        },
    }
}

fn completion_text(outcome: &ProviderOutcome, decision: &RouteDecision) -> String {
    outcome.content.clone().unwrap_or_else(|| {
        format!(
            "Mock Ingary response via {} for {} estimated tokens.",
            decision.selected_model, decision.estimated_prompt_tokens
        )
    })
}

async fn complete_with_ollama(
    target: &RouteTarget,
    request: &ChatCompletionRequest,
) -> Result<String, String> {
    let model = provider_model(target);
    let base_url = target.provider_base_url.as_deref().unwrap_or("").trim();
    let base_url = if base_url.is_empty() {
        std::env::var("OLLAMA_BASE_URL").unwrap_or_else(|_| "http://127.0.0.1:11434".to_string())
    } else {
        base_url.to_string()
    };
    let messages = request_messages(request);
    let body = json!({"model": model, "messages": messages, "stream": false});
    let response = reqwest::Client::new()
        .post(format!("{}/api/chat", base_url.trim_end_matches('/')))
        .json(&body)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("ollama returned {}", response.status().as_u16()));
    }
    let body: Value = response.json().await.map_err(|error| error.to_string())?;
    body.get("message")
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| "ollama response did not include message.content".to_string())
}

async fn complete_with_openai_compatible(
    target: &RouteTarget,
    request: &ChatCompletionRequest,
) -> Result<String, String> {
    let base_url = target
        .provider_base_url
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "provider_base_url is required for openai-compatible targets".to_string())?;
    let secret = provider_credential(target)?;
    let body = json!({
        "model": provider_model(target),
        "messages": request_messages(request),
        "stream": false
    });
    let mut request_builder = reqwest::Client::new()
        .post(format!(
            "{}/chat/completions",
            base_url.trim_end_matches('/')
        ))
        .bearer_auth(secret);
    for (key, value) in &target.provider_headers {
        request_builder = request_builder.header(key, value);
    }
    let response = request_builder
        .json(&body)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("provider returned {}", response.status().as_u16()));
    }
    let body: Value = response.json().await.map_err(|error| error.to_string())?;
    body.get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| "provider response did not include choices[0].message.content".to_string())
}

fn apply_provider_outcome(receipt: &mut Receipt, outcome: &ProviderOutcome) {
    if let Some(Value::Object(attempt)) = receipt.attempts.first_mut() {
        attempt.insert("status".to_string(), Value::String(outcome.status.clone()));
        attempt.insert("mock".to_string(), Value::Bool(outcome.mock));
        attempt.insert(
            "called_provider".to_string(),
            Value::Bool(outcome.called_provider),
        );
        attempt.insert(
            "latency_ms".to_string(),
            Value::Number(serde_json::Number::from(outcome.latency_ms as u64)),
        );
        if let Some(error) = &outcome.error {
            attempt.insert("provider_error".to_string(), Value::String(error.clone()));
        }
    }
    if let Value::Object(final_result) = &mut receipt.final_result {
        final_result.insert("status".to_string(), Value::String(outcome.status.clone()));
        if let Some(error) = &outcome.error {
            final_result.insert("provider_error".to_string(), Value::String(error.clone()));
        }
    }
}

fn append_provider_attempt(receipt: &mut Receipt, selected_model: &str, outcome: &ProviderOutcome) {
    receipt.attempts.push(json!({
        "provider_id": selected_model.split('/').next().unwrap_or("mock"),
        "model": selected_model,
        "status": outcome.status,
        "mock": outcome.mock,
        "called_provider": outcome.called_provider,
        "latency_ms": outcome.latency_ms,
        "retry_reason": "stream_policy_retry"
    }));
}

fn evaluate_stream_governance(
    content: &str,
    cfg: &TestConfig,
    retry_allowed: bool,
) -> StreamGovernanceResult {
    let chunks = chunk_text(content, 8);
    evaluate_stream_governance_chunks(&chunks, cfg, retry_allowed)
}

fn evaluate_stream_governance_chunks(
    chunks: &[String],
    cfg: &TestConfig,
    retry_allowed: bool,
) -> StreamGovernanceResult {
    let attempt = evaluate_stream_attempt(chunks, &cfg.stream_rules);
    let Some(matched) = attempt.matched.clone() else {
        return StreamGovernanceResult {
            content: attempt.content,
            released_chunks: attempt.released_chunks,
            ..StreamGovernanceResult::default()
        };
    };

    let mut result = StreamGovernanceResult {
        content: attempt.content,
        released_chunks: attempt.released_chunks,
        trigger_count: 1,
        alert_count: 1,
        actions: vec![json!({
            "rule_id": matched.rule_id,
            "phase": "response.streaming",
            "action": matched.action,
            "matched": true,
            "matcher": matched.matcher,
            "retry_allowed": retry_allowed
        })],
        events: vec![json!({
            "type": "stream.rule_matched",
            "rule_id": matched.rule_id,
            "phase": "response.streaming",
            "action": matched.action,
            "matcher": matched.matcher,
            "pattern_len_bytes": matched.pattern_len_bytes,
            "match_offset_bytes": matched.match_offset_bytes,
            "released_before_trigger_bytes": matched.released_before_trigger_bytes,
            "released_to_consumer": false
        })],
        final_status: Some("blocked_by_policy".to_string()),
        retry: None,
        retry_attempted: false,
    };

    if matched.action == "retry_with_reminder" && retry_allowed && matched.max_retries > 0 {
        result.final_status = Some("stream_retry_requested".to_string());
        result.retry = Some(StreamRetry {
            rule_id: matched.rule_id.clone(),
            reminder: matched.reminder.clone(),
        });
        result.events.push(json!({
            "type": "stream.retry_requested",
            "rule_id": matched.rule_id,
            "phase": "response.streaming",
            "released_to_consumer": false
        }));
    } else if matched.action == "annotate" || matched.action == "alert" {
        result.content = chunks.concat();
        result.released_chunks = chunk_text(&result.content, 8);
        result.final_status = None;
    } else {
        result.content = format!(
            "{}[blocked by stream governance]",
            attempt.released_before_trigger
        );
        result.released_chunks = chunk_text(&result.content, 8);
    }

    result
}

impl StreamGovernanceResult {
    fn with_retry_result(mut self, mut retry: StreamGovernanceResult) -> StreamGovernanceResult {
        let first_rule_id = self.retry.as_ref().map(|retry| retry.rule_id.clone());
        let mut actions = std::mem::take(&mut self.actions);
        actions.append(&mut retry.actions);
        let mut events = std::mem::take(&mut self.events);
        events.append(&mut retry.events);
        if retry.final_status.is_none() {
            retry.final_status = Some("completed_after_stream_retry".to_string());
        }
        if let Some(rule_id) = first_rule_id {
            events.push(json!({
                "type": "stream.retry_completed",
                "rule_id": rule_id,
                "phase": "response.streaming",
                "status": retry.final_status
                    .as_deref()
                    .unwrap_or("completed_after_stream_retry")
            }));
        }
        StreamGovernanceResult {
            content: retry.content,
            released_chunks: retry.released_chunks,
            trigger_count: self.trigger_count + retry.trigger_count,
            alert_count: self.alert_count + retry.alert_count,
            actions,
            events,
            final_status: retry.final_status,
            retry: None,
            retry_attempted: true,
        }
    }

    fn finish_reason(&self) -> &'static str {
        if self.final_status.as_deref() == Some("blocked_by_policy") {
            "content_filter"
        } else {
            "stop"
        }
    }
}

fn evaluate_stream_attempt(chunks: &[String], rules: &[StreamRule]) -> StreamAttemptResult {
    let active_rules: Vec<&StreamRule> = rules
        .iter()
        .filter(|rule| rule.active_pattern().is_some())
        .collect();
    if active_rules.is_empty() {
        let content = chunks.concat();
        return StreamAttemptResult {
            released_chunks: chunks.to_vec(),
            released_before_trigger: content.clone(),
            content,
            matched: None,
        };
    }

    let horizon = active_rules
        .iter()
        .map(|rule| rule.horizon_bytes())
        .max()
        .unwrap_or(0);
    let mut held = String::new();
    let mut released = String::new();
    let mut released_chunks = Vec::new();

    for chunk in chunks {
        held.push_str(chunk);
        if let Some(matched) = first_stream_match(&held, &released, &active_rules) {
            return StreamAttemptResult {
                content: released.clone(),
                released_chunks,
                released_before_trigger: released,
                matched: Some(matched),
            };
        }
        release_safe_stream_prefix(&mut held, &mut released, &mut released_chunks, horizon);
    }

    if !held.is_empty() {
        released.push_str(&held);
        released_chunks.push(held);
    }

    StreamAttemptResult {
        content: released.clone(),
        released_chunks,
        released_before_trigger: released,
        matched: None,
    }
}

fn first_stream_match(held: &str, released: &str, rules: &[&StreamRule]) -> Option<StreamMatch> {
    let released_bytes = released.len();
    rules
        .iter()
        .filter_map(|rule| rule.match_in(held, released_bytes))
        .min_by(|left, right| {
            left.match_offset_bytes
                .cmp(&right.match_offset_bytes)
                .then_with(|| left.rule_id.cmp(&right.rule_id))
        })
}

fn release_safe_stream_prefix(
    held: &mut String,
    released: &mut String,
    released_chunks: &mut Vec<String>,
    horizon: usize,
) {
    if held.len() <= horizon {
        return;
    }
    let split_at = release_prefix_byte_len(held, held.len() - horizon);
    let safe_prefix = held[..split_at].to_string();
    released.push_str(&safe_prefix);
    released_chunks.push(safe_prefix);
    *held = held[split_at..].to_string();
}

fn release_prefix_byte_len(value: &str, target_bytes: usize) -> usize {
    if target_bytes >= value.len() {
        return value.len();
    }
    let mut split_at = 0;
    for (index, ch) in value.char_indices() {
        let next = index + ch.len_utf8();
        if next > target_bytes {
            break;
        }
        split_at = next;
    }
    split_at
}

fn chunk_text(content: &str, chunk_chars: usize) -> Vec<String> {
    if content.is_empty() {
        return vec![String::new()];
    }
    let chunk_chars = chunk_chars.max(1);
    let mut chunks = Vec::new();
    let mut current = String::new();
    for ch in content.chars() {
        current.push(ch);
        if current.chars().count() >= chunk_chars {
            chunks.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    chunks
}

fn apply_stream_governance_to_receipt(receipt: &mut Receipt, stream: &StreamGovernanceResult) {
    if let Value::Object(decision) = &mut receipt.decision {
        decision.insert(
            "stream_policy_actions".to_string(),
            Value::Array(stream.actions.clone()),
        );
    }
    if let Value::Object(final_result) = &mut receipt.final_result {
        final_result.insert(
            "stream_trigger_count".to_string(),
            Value::Number(serde_json::Number::from(stream.trigger_count)),
        );
        let alert_count = final_result
            .get("alert_count")
            .and_then(Value::as_u64)
            .unwrap_or(0)
            + stream.alert_count;
        final_result.insert(
            "alert_count".to_string(),
            Value::Number(serde_json::Number::from(alert_count)),
        );
        if let Some(status) = &stream.final_status {
            final_result.insert("status".to_string(), Value::String(status.clone()));
        }
        let events = final_result
            .entry("events".to_string())
            .or_insert_with(|| Value::Array(Vec::new()));
        if let Value::Array(events) = events {
            events.extend(stream.events.clone());
        }
        final_result.insert(
            "stream_governance".to_string(),
            json!({
                "mode": "buffered_horizon",
                "trigger_count": stream.trigger_count,
                "retry_attempted": stream.retry_attempted,
                "released_chunk_count": stream.released_chunks.len(),
                "final_status": stream.final_status
            }),
        );
    }
}

fn sse_chat_response(
    created: u64,
    normalized_model: &str,
    selected_model: &str,
    receipt_id: &str,
    chunks: &[String],
    finish_reason: &str,
) -> Result<Response, ApiError> {
    let id = format!("chatcmpl-{}", Uuid::new_v4());
    let model = format!("ingary/{normalized_model}");
    let mut body = String::new();
    for (index, chunk) in chunks.iter().enumerate() {
        let delta = if index == 0 {
            json!({"role": "assistant", "content": chunk})
        } else {
            json!({"content": chunk})
        };
        body.push_str("data: ");
        body.push_str(
            &json!({
                "id": id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{
                    "index": 0,
                    "delta": delta,
                    "finish_reason": Value::Null
                }],
                "ingary": {
                    "receipt_id": receipt_id,
                    "selected_model": selected_model
                }
            })
            .to_string(),
        );
        body.push_str("\n\n");
    }
    body.push_str("data: ");
    body.push_str(
        &json!({
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": finish_reason
            }],
            "ingary": {
                "receipt_id": receipt_id,
                "selected_model": selected_model
            }
        })
        .to_string(),
    );
    body.push_str("\n\ndata: [DONE]\n\n");

    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "text/event-stream; charset=utf-8")
        .header("cache-control", "no-cache")
        .header(
            "X-Ingary-Receipt-Id",
            HeaderValue::from_str(receipt_id).map_err(|_| ApiError::internal())?,
        )
        .header(
            "X-Ingary-Selected-Model",
            HeaderValue::from_str(selected_model).map_err(|_| ApiError::internal())?,
        )
        .body(Body::from(body))
        .map_err(|_| ApiError::internal())
}

fn request_messages(request: &ChatCompletionRequest) -> Vec<Value> {
    request
        .messages
        .iter()
        .map(|message| {
            json!({
                "role": message.role,
                "content": message.content.as_str().map(ToOwned::to_owned).unwrap_or_else(|| message.content.to_string())
            })
        })
        .collect()
}

fn provider_kind(target: &RouteTarget) -> &str {
    target
        .provider_kind
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            if target.model.starts_with("ollama/") {
                "ollama"
            } else {
                "mock"
            }
        })
}

fn provider_model(target: &RouteTarget) -> String {
    target
        .model
        .split_once('/')
        .map(|(_, model)| model.trim())
        .filter(|model| !model.is_empty())
        .unwrap_or(target.model.trim())
        .to_string()
}

fn credential_source(target: &RouteTarget) -> &str {
    if target
        .credential_fnox_key
        .as_deref()
        .map(str::trim)
        .is_some_and(|value| !value.is_empty())
    {
        "fnox"
    } else if target
        .credential_env
        .as_deref()
        .map(str::trim)
        .is_some_and(|value| !value.is_empty())
    {
        "env"
    } else {
        "none"
    }
}

fn provider_credential(target: &RouteTarget) -> Result<String, String> {
    if let Some(env_key) = target
        .credential_env
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return std::env::var(env_key)
            .map(|value| value.trim().to_string())
            .map_err(|_| format!("credential env var {env_key} is not set"))
            .and_then(|value| {
                if value.is_empty() {
                    Err(format!("credential env var {env_key} is empty"))
                } else {
                    Ok(value)
                }
            });
    }
    if let Some(fnox_key) = target
        .credential_fnox_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let output = Command::new("fnox")
            .args(["get", fnox_key])
            .output()
            .map_err(|_| format!("fnox credential {fnox_key} is unavailable"))?;
        if !output.status.success() {
            return Err(format!("fnox credential {fnox_key} is unavailable"));
        }
        let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if value.is_empty() {
            Err(format!("fnox credential {fnox_key} is empty"))
        } else {
            Ok(value)
        }
    } else {
        Err("credential_env or credential_fnox_key is required".to_string())
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

#[cfg(test)]
fn evaluate_request_policies(
    request: &mut ChatCompletionRequest,
    cfg: &TestConfig,
) -> PolicyResult {
    evaluate_request_policies_with_cache(request, cfg, &CallerContext::default(), None)
}

fn evaluate_request_policies_with_cache(
    request: &mut ChatCompletionRequest,
    cfg: &TestConfig,
    caller: &CallerContext,
    cache: Option<&MemoryPolicyCache>,
) -> PolicyResult {
    let mut result = PolicyResult::default();
    let text = request_text(&request.messages).to_lowercase();
    for rule in &cfg.governance {
        let kind = rule.get("kind").and_then(Value::as_str).unwrap_or_default();
        if kind == "history_threshold" {
            let threshold = rule
                .get("threshold")
                .and_then(Value::as_u64)
                .filter(|threshold| *threshold > 0)
                .unwrap_or(1) as usize;
            let cache_kind = rule
                .get("cache_kind")
                .and_then(Value::as_str)
                .and_then(|value| nonblank(Some(value)))
                .map(str::to_string);
            let cache_key = rule
                .get("cache_key")
                .and_then(Value::as_str)
                .and_then(|value| nonblank(Some(value)))
                .map(str::to_string);
            let cache_scope = rule
                .get("cache_scope")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            let filter = PolicyCacheFilter {
                kind: cache_kind,
                key: cache_key,
                scope: cache_scope_from_caller(caller, cache_scope),
            };
            let count = cache.map(|cache| cache.count(&filter)).unwrap_or(0);
            if count < threshold {
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
                .unwrap_or("policy cache threshold matched");
            let severity = rule
                .get("severity")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or("info");
            result.actions.push(json!({
                "rule_id": rule_id,
                "kind": kind,
                "action": action,
                "matched": true,
                "message": message,
                "severity": severity,
                "cache_kind": rule.get("cache_kind").and_then(Value::as_str).unwrap_or_default(),
                "cache_key": rule.get("cache_key").and_then(Value::as_str).unwrap_or_default(),
                "cache_scope": cache_scope,
                "history_count": count,
                "threshold": threshold
            }));
            if action == "escalate" {
                result.alert_count += 1;
                result.events.push(json!({
                    "type": "policy.alert",
                    "rule_id": rule_id,
                    "message": message,
                    "severity": severity,
                    "history_count": count,
                    "threshold": threshold
                }));
            }
            continue;
        }
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
    metadata: Option<Value>,
    #[serde(flatten)]
    extra: HashMap<String, Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct ChatMessage {
    #[serde(default)]
    role: String,
    #[serde(default)]
    content: Value,
    #[serde(default)]
    name: Option<String>,
    #[serde(flatten)]
    extra: HashMap<String, Value>,
}

impl ChatCompletionRequest {
    fn from_value(value: Value) -> Self {
        let object = value.as_object();
        let model = object
            .and_then(|object| object.get("model"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let stream = object
            .and_then(|object| object.get("stream"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let metadata = object.and_then(|object| object.get("metadata")).cloned();
        let messages = object
            .and_then(|object| object.get("messages"))
            .and_then(Value::as_array)
            .map(|messages| {
                messages
                    .iter()
                    .filter_map(ChatMessage::from_value)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        Self {
            model,
            messages,
            stream,
            metadata,
            extra: HashMap::new(),
        }
    }

    fn metadata_map(&self) -> Option<&Map<String, Value>> {
        self.metadata.as_ref().and_then(Value::as_object)
    }
}

impl ChatMessage {
    fn from_value(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        Some(Self {
            role: object
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            content: object.get("content").cloned().unwrap_or(Value::Null),
            name: object
                .get("name")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            extra: HashMap::new(),
        })
    }
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
    #[serde(default)]
    policy_cache: PolicyCacheConfig,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
struct PolicyCacheConfig {
    #[serde(default)]
    max_entries: usize,
    #[serde(default)]
    recent_limit: usize,
}

impl Default for PolicyCacheConfig {
    fn default() -> Self {
        Self {
            max_entries: 64,
            recent_limit: 20,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct PolicyCacheEventInput {
    kind: String,
    #[serde(default)]
    key: String,
    #[serde(default)]
    scope: HashMap<String, String>,
    #[serde(default)]
    value: Map<String, Value>,
    #[serde(default)]
    created_at_unix_ms: i64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct PolicyCacheEvent {
    id: String,
    sequence: u64,
    kind: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    key: String,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    scope: HashMap<String, String>,
    #[serde(skip_serializing_if = "Map::is_empty")]
    value: Map<String, Value>,
    created_at_unix_ms: i64,
}

#[derive(Debug, Clone, Deserialize)]
struct PolicyCacheQuery {
    kind: Option<String>,
    key: Option<String>,
    tenant_id: Option<String>,
    application_id: Option<String>,
    consuming_agent_id: Option<String>,
    consuming_user_id: Option<String>,
    session_id: Option<String>,
    run_id: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Clone, Default)]
struct PolicyCacheFilter {
    kind: Option<String>,
    key: Option<String>,
    scope: HashMap<String, String>,
}

#[derive(Debug, Clone)]
struct MemoryPolicyCache {
    config: PolicyCacheConfig,
    next: u64,
    events: Vec<PolicyCacheEvent>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct RouteTarget {
    model: String,
    context_window: u64,
    #[serde(default)]
    provider_kind: Option<String>,
    #[serde(default)]
    provider_base_url: Option<String>,
    #[serde(default)]
    provider_headers: HashMap<String, String>,
    #[serde(default)]
    credential_env: Option<String>,
    #[serde(default)]
    credential_fnox_key: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct StreamRule {
    id: Option<String>,
    #[serde(default)]
    matcher: Option<String>,
    pattern: Option<String>,
    #[serde(default)]
    horizon_bytes: Option<usize>,
    #[serde(default)]
    action: String,
    #[serde(default)]
    reminder: Option<String>,
    #[serde(default)]
    max_retries: Option<u32>,
    #[serde(default)]
    on_retry_violation: Option<String>,
}

impl StreamRule {
    fn rule_id(&self) -> String {
        self.id
            .as_deref()
            .and_then(|value| nonblank(Some(value)))
            .unwrap_or("stream_policy")
            .to_string()
    }

    fn matcher(&self) -> &str {
        self.matcher
            .as_deref()
            .and_then(|value| nonblank(Some(value)))
            .unwrap_or("literal")
    }

    fn active_pattern(&self) -> Option<&str> {
        if self.action.trim() == "pass" {
            return None;
        }
        self.pattern
            .as_deref()
            .and_then(|value| nonblank(Some(value)))
    }

    fn horizon_bytes(&self) -> usize {
        self.active_pattern()
            .map(|pattern| {
                self.horizon_bytes
                    .unwrap_or(pattern.len())
                    .max(pattern.len())
            })
            .unwrap_or(0)
    }

    fn action(&self) -> &str {
        match self.action.trim() {
            "inject_reminder_and_retry" => "retry_with_reminder",
            "block" | "block_final" => "block_final",
            "alert" => "alert",
            "annotate" => "annotate",
            "retry_with_reminder" => "retry_with_reminder",
            _ => "block_final",
        }
    }

    fn retry_reminder(&self) -> String {
        self.reminder
            .as_deref()
            .and_then(|value| nonblank(Some(value)))
            .unwrap_or(
                "A streamed governance rule matched. Retry without producing the matched content.",
            )
            .to_string()
    }

    fn match_in(&self, held: &str, released_bytes: usize) -> Option<StreamMatch> {
        let pattern = self.active_pattern()?;
        let matcher = self.matcher();
        let (start_byte, end_byte) = match matcher {
            "regex" => regex::Regex::new(pattern).ok().and_then(|regex| {
                regex
                    .find(held)
                    .map(|matched| (matched.start(), matched.end()))
            }),
            "literal" | "contains" => held
                .find(pattern)
                .map(|start| (start, start + pattern.len())),
            _ => held
                .find(pattern)
                .map(|start| (start, start + pattern.len())),
        }?;
        Some(StreamMatch {
            rule_id: self.rule_id(),
            action: self.action().to_string(),
            matcher: matcher.to_string(),
            pattern_len_bytes: end_byte - start_byte,
            match_offset_bytes: released_bytes + start_byte,
            released_before_trigger_bytes: released_bytes,
            reminder: self.retry_reminder(),
            max_retries: self.max_retries.unwrap_or(1),
        })
    }
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
                    provider_kind: None,
                    provider_base_url: None,
                    provider_headers: HashMap::new(),
                    credential_env: None,
                    credential_fnox_key: None,
                },
                RouteTarget {
                    model: MANAGED_MODEL.to_string(),
                    context_window: MANAGED_CONTEXT_WINDOW,
                    provider_kind: None,
                    provider_base_url: None,
                    provider_headers: HashMap::new(),
                    credential_env: None,
                    credential_fnox_key: None,
                },
            ],
            stream_rules: vec![StreamRule {
                id: Some("mock_noop".to_string()),
                matcher: Some("literal".to_string()),
                pattern: Some("".to_string()),
                horizon_bytes: Some(256),
                action: "pass".to_string(),
                reminder: None,
                max_retries: None,
                on_retry_violation: None,
            }],
            prompt_transforms: None,
            structured_output: None,
            governance: vec![json!({
                "id": "prompt_transforms",
                "kind": "request_transform",
                "action": "transform"
            })],
            policy_cache: PolicyCacheConfig::default(),
        }
    }
}

impl TestConfig {
    fn normalize(&mut self) {
        if self.version.trim().is_empty() {
            self.version = SYNTHETIC_VERSION.to_string();
        }
        if self.policy_cache.max_entries == 0 {
            self.policy_cache.max_entries = 64;
        }
        if self.policy_cache.recent_limit == 0 {
            self.policy_cache.recent_limit = 20;
        }
        self.synthetic_model = self.synthetic_model.trim().to_string();
        for target in &mut self.targets {
            target.model = target.model.trim().to_string();
            target.provider_kind = trim_optional(target.provider_kind.take());
            target.provider_base_url = trim_optional(target.provider_base_url.take());
            target.provider_headers = std::mem::take(&mut target.provider_headers)
                .into_iter()
                .filter_map(|(key, value)| {
                    let key = key.trim().to_string();
                    let value = value.trim().to_string();
                    if key.is_empty()
                        || value.is_empty()
                        || key.eq_ignore_ascii_case("authorization")
                    {
                        None
                    } else {
                        Some((key, value))
                    }
                })
                .collect();
            target.credential_env = trim_optional(target.credential_env.take());
            target.credential_fnox_key = trim_optional(target.credential_fnox_key.take());
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
            if target.has_credential_reference()
                && std::env::var("INGARY_ALLOW_TEST_CREDENTIALS")
                    .ok()
                    .as_deref()
                    != Some("1")
            {
                return Err(
                    "credential references in __test/config require INGARY_ALLOW_TEST_CREDENTIALS=1"
                        .to_string(),
                );
            }
        }
        for rule in &self.stream_rules {
            if rule.matcher() == "regex" {
                if let Some(pattern) = rule.active_pattern() {
                    regex::Regex::new(pattern).map_err(|error| {
                        format!(
                            "stream rule {} regex does not compile: {error}",
                            rule.rule_id()
                        )
                    })?;
                }
            }
        }
        Ok(())
    }
}

impl RouteTarget {
    fn has_credential_reference(&self) -> bool {
        self.credential_env
            .as_deref()
            .map(str::trim)
            .is_some_and(|value| !value.is_empty())
            || self
                .credential_fnox_key
                .as_deref()
                .map(str::trim)
                .is_some_and(|value| !value.is_empty())
    }
}

impl MemoryPolicyCache {
    fn new(config: PolicyCacheConfig) -> Self {
        let mut cache = Self {
            config,
            next: 0,
            events: Vec::new(),
        };
        cache.normalize_config();
        cache
    }

    fn configure(&mut self, config: PolicyCacheConfig) {
        self.config = config;
        self.next = 0;
        self.events.clear();
        self.normalize_config();
    }

    fn add(&mut self, input: PolicyCacheEventInput) -> Result<PolicyCacheEvent, String> {
        let kind = input.kind.trim().to_string();
        if kind.is_empty() {
            return Err("kind must not be empty".to_string());
        }
        if input.created_at_unix_ms < 0 {
            return Err("created_at_unix_ms must not be negative".to_string());
        }
        if self.config.max_entries < 1 {
            return Err("policy cache is disabled".to_string());
        }
        self.next += 1;
        let event = PolicyCacheEvent {
            id: format!("pc_{:016x}", self.next),
            sequence: self.next,
            kind,
            key: input.key.trim().to_string(),
            scope: clean_string_map(input.scope),
            value: input.value,
            created_at_unix_ms: input.created_at_unix_ms,
        };
        self.events.push(event.clone());
        self.evict();
        Ok(event)
    }

    fn recent(&self, filter: &PolicyCacheFilter, limit: usize) -> Vec<PolicyCacheEvent> {
        let limit = if limit == 0 || limit > self.config.recent_limit {
            self.config.recent_limit
        } else {
            limit
        };
        if limit == 0 {
            return Vec::new();
        }
        self.events
            .iter()
            .rev()
            .filter(|event| policy_cache_matches(event, filter))
            .take(limit)
            .cloned()
            .collect()
    }

    fn count(&self, filter: &PolicyCacheFilter) -> usize {
        self.recent(filter, self.config.max_entries).len()
    }

    fn evict(&mut self) {
        self.events.sort_by(|left, right| {
            left.created_at_unix_ms
                .cmp(&right.created_at_unix_ms)
                .then_with(|| left.sequence.cmp(&right.sequence))
        });
        while self.events.len() > self.config.max_entries {
            self.events.remove(0);
        }
        self.events
            .sort_by(|left, right| left.sequence.cmp(&right.sequence));
    }

    fn normalize_config(&mut self) {
        if self.config.max_entries == 0 {
            self.config.max_entries = 64;
        }
        if self.config.recent_limit == 0 {
            self.config.recent_limit = 20;
        }
    }
}

impl From<PolicyCacheQuery> for PolicyCacheFilter {
    fn from(query: PolicyCacheQuery) -> Self {
        let mut scope = HashMap::new();
        for (key, value) in [
            ("tenant_id", query.tenant_id),
            ("application_id", query.application_id),
            ("consuming_agent_id", query.consuming_agent_id),
            ("consuming_user_id", query.consuming_user_id),
            ("session_id", query.session_id),
            ("run_id", query.run_id),
        ] {
            if let Some(value) = value.and_then(|value| {
                let value = value.trim().to_string();
                (!value.is_empty()).then_some(value)
            }) {
                scope.insert(key.to_string(), value);
            }
        }
        Self {
            kind: trim_optional(query.kind),
            key: trim_optional(query.key),
            scope,
        }
    }
}

fn policy_cache_matches(event: &PolicyCacheEvent, filter: &PolicyCacheFilter) -> bool {
    if filter
        .kind
        .as_deref()
        .is_some_and(|kind| event.kind != kind)
    {
        return false;
    }
    if filter.key.as_deref().is_some_and(|key| event.key != key) {
        return false;
    }
    filter
        .scope
        .iter()
        .all(|(key, value)| event.scope.get(key) == Some(value))
}

fn cache_scope_from_caller(caller: &CallerContext, scope_name: &str) -> HashMap<String, String> {
    let value = match scope_name {
        "tenant_id" => caller.tenant_id.as_ref(),
        "application_id" => caller.application_id.as_ref(),
        "consuming_agent_id" => caller.consuming_agent_id.as_ref(),
        "consuming_user_id" => caller.consuming_user_id.as_ref(),
        "session_id" => caller.session_id.as_ref(),
        "run_id" => caller.run_id.as_ref(),
        _ => None,
    };
    value
        .map(|value| HashMap::from([(scope_name.to_string(), value.value.clone())]))
        .unwrap_or_default()
}

fn clean_string_map(values: HashMap<String, String>) -> HashMap<String, String> {
    values
        .into_iter()
        .filter_map(|(key, value)| {
            let key = key.trim().to_string();
            let value = value.trim().to_string();
            if key.is_empty() || value.is_empty() {
                None
            } else {
                Some((key, value))
            }
        })
        .collect()
}

fn trim_optional(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct SourcedString {
    value: String,
    source: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{HeaderMap, HeaderValue};
    use hegel::TestCase;
    use hegel::generators as gs;

    fn chat_request(model: &str, content: &str) -> ChatCompletionRequest {
        ChatCompletionRequest {
            model: Some(model.to_string()),
            messages: vec![ChatMessage {
                role: "user".to_string(),
                content: Value::String(content.to_string()),
                name: None,
                extra: HashMap::new(),
            }],
            stream: false,
            metadata: None,
            extra: HashMap::new(),
        }
    }

    fn test_config() -> TestConfig {
        TestConfig {
            synthetic_model: "unit-model".to_string(),
            version: "unit-version".to_string(),
            targets: vec![
                RouteTarget {
                    model: "tiny/model".to_string(),
                    context_window: 8,
                    provider_kind: None,
                    provider_base_url: None,
                    provider_headers: HashMap::new(),
                    credential_env: None,
                    credential_fnox_key: None,
                },
                RouteTarget {
                    model: "medium/model".to_string(),
                    context_window: 32,
                    provider_kind: None,
                    provider_base_url: None,
                    provider_headers: HashMap::new(),
                    credential_env: None,
                    credential_fnox_key: None,
                },
                RouteTarget {
                    model: "large/model".to_string(),
                    context_window: 256,
                    provider_kind: None,
                    provider_base_url: None,
                    provider_headers: HashMap::new(),
                    credential_env: None,
                    credential_fnox_key: None,
                },
            ],
            stream_rules: Vec::new(),
            prompt_transforms: None,
            structured_output: None,
            governance: Vec::new(),
            policy_cache: PolicyCacheConfig::default(),
        }
    }

    fn literal_stream_rule(pattern: &str, action: &str) -> StreamRule {
        StreamRule {
            id: Some("unit-stream-rule".to_string()),
            matcher: Some("literal".to_string()),
            pattern: Some(pattern.to_string()),
            horizon_bytes: Some(pattern.len() + 4),
            action: action.to_string(),
            reminder: Some("Avoid the matched streamed content.".to_string()),
            max_retries: Some(1),
            on_retry_violation: Some("block_final".to_string()),
        }
    }

    fn regex_stream_rule(pattern: &str, action: &str) -> StreamRule {
        StreamRule {
            id: Some("unit-stream-regex-rule".to_string()),
            matcher: Some("regex".to_string()),
            pattern: Some(pattern.to_string()),
            horizon_bytes: Some(pattern.len() + 32),
            action: action.to_string(),
            reminder: Some("Avoid the matched streamed content.".to_string()),
            max_retries: Some(1),
            on_retry_violation: Some("block_final".to_string()),
        }
    }

    #[test]
    fn normalize_model_accepts_flat_and_ingary_prefixed_ids() {
        let cfg = test_config();

        assert_eq!(
            normalize_model(Some("unit-model"), &cfg),
            Some("unit-model".to_string())
        );
        assert_eq!(
            normalize_model(Some("ingary/unit-model"), &cfg),
            Some("unit-model".to_string())
        );
        assert_eq!(normalize_model(Some("other-model"), &cfg), None);
    }

    #[test]
    fn select_route_uses_smallest_context_window_that_fits() {
        let cfg = test_config();

        let tiny = select_route(&chat_request("unit-model", "short"), &cfg);
        assert_eq!(tiny.selected_model, "tiny/model");
        assert!(tiny.skipped.is_empty());

        let medium = select_route(&chat_request("unit-model", &"x".repeat(80)), &cfg);
        assert_eq!(medium.selected_model, "medium/model");
        assert_eq!(
            medium.skipped[0].get("target").and_then(Value::as_str),
            Some("tiny/model")
        );

        let fallback = select_route(&chat_request("unit-model", &"x".repeat(2000)), &cfg);
        assert_eq!(fallback.selected_model, "large/model");
        assert_eq!(fallback.skipped.len(), 3);
    }

    #[test]
    fn prompt_transforms_insert_named_system_messages_without_mutating_original() {
        let mut cfg = test_config();
        cfg.prompt_transforms = Some(PromptTransforms {
            preamble: Some("Use JSON.".to_string()),
            postscript: Some("Validate before answering.".to_string()),
        });
        let request = chat_request("unit-model", "hello");

        let transformed = apply_prompt_transforms(request.clone(), &cfg);

        assert_eq!(request.messages.len(), 1);
        assert_eq!(transformed.messages.len(), 3);
        assert_eq!(
            transformed.messages[0].name.as_deref(),
            Some("ingary_preamble")
        );
        assert_eq!(
            transformed.messages[2].name.as_deref(),
            Some("ingary_postscript")
        );
    }

    #[test]
    fn request_policy_records_alert_and_injected_reminder_actions() {
        let mut cfg = test_config();
        cfg.governance = vec![
            json!({
                "id": "ambiguous-success",
                "kind": "request_guard",
                "action": "escalate",
                "contains": "looks done",
                "message": "completion claim needs artifact",
                "severity": "warning"
            }),
            json!({
                "id": "json-reminder",
                "kind": "request_transform",
                "action": "inject_reminder_and_retry",
                "contains": "return json",
                "reminder": "Return only valid JSON."
            }),
        ];
        let mut request = chat_request("unit-model", "Looks done; return JSON for the caller");

        let policy = evaluate_request_policies(&mut request, &cfg);

        assert_eq!(policy.alert_count, 1);
        assert_eq!(policy.actions.len(), 2);
        assert_eq!(
            policy.events[0].get("type").and_then(Value::as_str),
            Some("policy.alert")
        );
        assert_eq!(
            request
                .messages
                .last()
                .and_then(|message| message.name.as_deref()),
            Some("ingary_policy_reminder")
        );
    }

    #[test]
    fn caller_headers_take_precedence_over_body_metadata() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "X-Ingary-Agent-Id",
            HeaderValue::from_static("header-agent"),
        );
        let mut metadata = Map::new();
        metadata.insert("consuming_agent_id".to_string(), json!("body-agent"));
        metadata.insert("user_id".to_string(), json!("body-user"));

        let caller = caller_from(headers, Some(&metadata));

        assert_eq!(
            caller
                .consuming_agent_id
                .as_ref()
                .map(|value| value.value.as_str()),
            Some("header-agent")
        );
        assert_eq!(
            caller
                .consuming_agent_id
                .as_ref()
                .map(|value| value.source.as_str()),
            Some("header")
        );
        assert_eq!(
            caller
                .consuming_user_id
                .as_ref()
                .map(|value| value.value.as_str()),
            Some("body-user")
        );
    }

    #[test]
    fn receipt_query_filters_by_prefixed_model_caller_and_status() {
        let cfg = test_config();
        let mut request = chat_request("ingary/unit-model", "hello");
        request.metadata = Some(json!({
            "consuming_agent_id": "agent-a",
            "session_id": "session-a"
        }));
        let caller = caller_from(HeaderMap::new(), request.metadata_map());
        let decision = select_route(&request, &cfg);
        let receipt = build_receipt(
            caller,
            cfg.synthetic_model.clone(),
            Some(request),
            decision,
            "simulated",
            &cfg,
            PolicyResult::default(),
        );

        assert!(
            ReceiptQuery {
                model: Some("ingary/unit-model".to_string()),
                consuming_agent_id: Some("agent-a".to_string()),
                consuming_user_id: None,
                session_id: Some("session-a".to_string()),
                run_id: None,
                status: Some("simulated".to_string()),
                limit: None,
            }
            .matches(&receipt)
        );
        assert!(
            !ReceiptQuery {
                model: Some("unit-model".to_string()),
                consuming_agent_id: Some("other-agent".to_string()),
                consuming_user_id: None,
                session_id: None,
                run_id: None,
                status: None,
                limit: None,
            }
            .matches(&receipt)
        );
    }

    #[test]
    fn test_config_validation_rejects_bad_route_graphs() {
        let mut cfg = test_config();
        assert!(cfg.validate().is_ok());

        cfg.synthetic_model = "ingary/unit-model".to_string();
        assert_eq!(
            cfg.validate().unwrap_err(),
            "synthetic_model must be unprefixed"
        );

        let mut cfg = test_config();
        cfg.targets.push(RouteTarget {
            model: "tiny/model".to_string(),
            context_window: 16,
            provider_kind: None,
            provider_base_url: None,
            provider_headers: HashMap::new(),
            credential_env: None,
            credential_fnox_key: None,
        });
        assert_eq!(cfg.validate().unwrap_err(), "duplicate target tiny/model");
    }

    #[test]
    fn test_config_validation_rejects_invalid_stream_regex() {
        let mut cfg = test_config();
        cfg.stream_rules = vec![regex_stream_rule("api[_-?key", "block_final")];

        assert!(
            cfg.validate()
                .unwrap_err()
                .starts_with("stream rule unit-stream-regex-rule regex does not compile:"),
            "invalid regex stream rules must fail closed"
        );
    }

    #[test]
    fn provider_metadata_reports_credential_source_without_names_or_values() {
        let cfg = TestConfig {
            synthetic_model: SYNTHETIC_MODEL_ID.to_string(),
            version: SYNTHETIC_VERSION.to_string(),
            targets: vec![RouteTarget {
                model: "openai/gpt-test".to_string(),
                context_window: 128_000,
                provider_kind: Some("openai-compatible".to_string()),
                provider_base_url: Some("https://example.com/v1".to_string()),
                provider_headers: HashMap::new(),
                credential_env: Some("INGARY_TEST_PROVIDER_KEY".to_string()),
                credential_fnox_key: None,
            }],
            stream_rules: Vec::new(),
            prompt_transforms: None,
            structured_output: None,
            governance: Vec::new(),
            policy_cache: PolicyCacheConfig::default(),
        };

        let providers = providers_for_config(&cfg);
        assert_eq!(providers.len(), 1);
        assert_eq!(providers[0]["credential_source"], "env");
        assert!(providers[0].get("credential_env").is_none());
        assert!(providers[0].get("credential").is_none());
    }

    #[test]
    fn provider_model_uses_suffix_after_provider_id() {
        let target = RouteTarget {
            model: "openai/gpt-test".to_string(),
            context_window: 128_000,
            provider_kind: Some("openai-compatible".to_string()),
            provider_base_url: Some("https://example.com/v1".to_string()),
            provider_headers: HashMap::new(),
            credential_env: None,
            credential_fnox_key: None,
        };

        assert_eq!(provider_model(&target), "gpt-test");
    }

    #[test]
    fn stream_policy_detects_literal_trigger_split_across_chunks() {
        let mut cfg = test_config();
        cfg.stream_rules = vec![literal_stream_rule("FORBIDDEN_CALL", "block_final")];
        let chunks = vec![
            "safe prefix FOR".to_string(),
            "BIDDEN_CALL unsafe suffix".to_string(),
        ];

        let result = evaluate_stream_governance_chunks(&chunks, &cfg, true);

        assert_eq!(result.trigger_count, 1);
        assert_eq!(result.final_status.as_deref(), Some("blocked_by_policy"));
        assert!(
            !result.content.contains("FORBIDDEN_CALL"),
            "blocked content must not release the matched trigger: {:?}",
            result.content
        );
        assert_eq!(
            result.events[0]
                .get("released_to_consumer")
                .and_then(Value::as_bool),
            Some(false)
        );
    }

    #[test]
    fn stream_policy_retry_blocks_when_retry_violates_again() {
        let mut cfg = test_config();
        cfg.stream_rules = vec![literal_stream_rule("FORBIDDEN_CALL", "retry_with_reminder")];
        let first = vec!["safe FOR".to_string(), "BIDDEN_CALL".to_string()];
        let retry = vec!["retry still FOR".to_string(), "BIDDEN_CALL".to_string()];

        let first = evaluate_stream_governance_chunks(&first, &cfg, true);
        assert!(first.retry.is_some());
        let retry = evaluate_stream_governance_chunks(&retry, &cfg, false);
        let result = first.with_retry_result(retry);

        assert_eq!(result.trigger_count, 2);
        assert!(result.retry_attempted);
        assert_eq!(result.final_status.as_deref(), Some("blocked_by_policy"));
        assert!(!result.content.contains("FORBIDDEN_CALL"));
    }

    #[test]
    fn stream_policy_horizon_counts_utf8_bytes_without_splitting_codepoints() {
        let mut cfg = test_config();
        cfg.stream_rules = vec![literal_stream_rule("DENYMARK", "block_final")];
        let chunks = vec!["prefix 😀 DEN".to_string(), "YMARK tail".to_string()];

        let result = evaluate_stream_governance_chunks(&chunks, &cfg, true);

        assert_eq!(result.trigger_count, 1);
        assert_eq!(result.final_status.as_deref(), Some("blocked_by_policy"));
        assert!(
            result
                .released_chunks
                .iter()
                .all(|chunk| std::str::from_utf8(chunk.as_bytes()).is_ok()),
            "released chunks must remain valid UTF-8: {:?}",
            result.released_chunks
        );
        assert!(!result.content.contains("DENYMARK"));
    }

    #[test]
    fn stream_policy_regex_trigger_matches_across_chunks() {
        let mut cfg = test_config();
        cfg.stream_rules = vec![regex_stream_rule(r"api[_-]?key\s*=", "block_final")];
        let chunks = vec![
            "let api".to_string(),
            "_key ".to_string(),
            "= value".to_string(),
        ];

        let result = evaluate_stream_governance_chunks(&chunks, &cfg, true);

        assert_eq!(result.trigger_count, 1);
        assert_eq!(result.final_status.as_deref(), Some("blocked_by_policy"));
        assert!(!result.content.contains("api_key ="));
        assert_eq!(
            result.events[0].get("matcher").and_then(Value::as_str),
            Some("regex")
        );
    }

    #[hegel::test]
    fn stream_policy_does_not_release_split_trigger_before_match(tc: TestCase) {
        let prefix_len = tc.draw(gs::integers::<usize>().min_value(0).max_value(32));
        let suffix_len = tc.draw(gs::integers::<usize>().min_value(0).max_value(32));
        let split = tc.draw(gs::integers::<usize>().min_value(1).max_value(8));
        let pattern = "DENYMARK";
        let prefix = "a".repeat(prefix_len);
        let suffix = "z".repeat(suffix_len);
        let chunks = vec![
            format!("{}{}", prefix, &pattern[..split]),
            format!("{}{}", &pattern[split..], suffix),
        ];
        let mut cfg = test_config();
        cfg.stream_rules = vec![literal_stream_rule(pattern, "block_final")];

        let attempt = evaluate_stream_attempt(&chunks, &cfg.stream_rules);

        assert!(
            attempt.matched.is_some(),
            "split trigger should match across chunks; chunks={chunks:?}"
        );
        assert!(
            !attempt.released_before_trigger.contains(pattern),
            "trigger bytes were released before policy matched; released={:?}",
            attempt.released_before_trigger
        );
        assert!(
            !attempt.content.contains(pattern),
            "attempt content should stop before the violating span; content={:?}",
            attempt.content
        );
    }

    #[hegel::test]
    fn policy_cache_eviction_keeps_deterministic_youngest_entries(tc: TestCase) {
        let capacity = tc.draw(gs::integers::<usize>().min_value(1).max_value(20));
        let timestamps =
            tc.draw(gs::vecs(gs::integers::<i64>().min_value(0).max_value(50)).max_size(80));
        let mut cache = MemoryPolicyCache::new(PolicyCacheConfig {
            max_entries: capacity,
            recent_limit: capacity,
        });
        let mut inserted = Vec::new();
        for timestamp in timestamps {
            let event = cache
                .add(PolicyCacheEventInput {
                    kind: "tool_call".to_string(),
                    key: "shell:ls".to_string(),
                    scope: HashMap::from([("session_id".to_string(), "session-a".to_string())]),
                    value: Map::new(),
                    created_at_unix_ms: timestamp,
                })
                .expect("event should be accepted");
            inserted.push((event.sequence, timestamp));
        }
        inserted.sort_by(|left, right| left.1.cmp(&right.1).then_with(|| left.0.cmp(&right.0)));
        if inserted.len() > capacity {
            inserted = inserted[inserted.len() - capacity..].to_vec();
        }
        let expected: std::collections::HashSet<u64> =
            inserted.into_iter().map(|(sequence, _)| sequence).collect();
        let recent = cache.recent(
            &PolicyCacheFilter {
                kind: Some("tool_call".to_string()),
                key: Some("shell:ls".to_string()),
                scope: HashMap::from([("session_id".to_string(), "session-a".to_string())]),
            },
            capacity,
        );
        assert_eq!(recent.len(), expected.len());
        assert!(
            recent
                .iter()
                .all(|event| expected.contains(&event.sequence)),
            "recent={recent:?} expected={expected:?}"
        );
    }

    #[test]
    fn history_threshold_policy_reads_only_configured_scope() {
        let mut cfg = test_config();
        cfg.governance = vec![json!({
            "id": "repeat-tool",
            "kind": "history_threshold",
            "action": "escalate",
            "cache_kind": "tool_call",
            "cache_key": "shell:ls",
            "cache_scope": "session_id",
            "threshold": 2,
            "severity": "warning"
        })];
        let mut cache = MemoryPolicyCache::new(PolicyCacheConfig {
            max_entries: 8,
            recent_limit: 8,
        });
        cache
            .add(PolicyCacheEventInput {
                kind: "tool_call".to_string(),
                key: "shell:ls".to_string(),
                scope: HashMap::from([("session_id".to_string(), "session-a".to_string())]),
                value: Map::new(),
                created_at_unix_ms: 1,
            })
            .unwrap();
        cache
            .add(PolicyCacheEventInput {
                kind: "tool_call".to_string(),
                key: "shell:ls".to_string(),
                scope: HashMap::from([("session_id".to_string(), "session-b".to_string())]),
                value: Map::new(),
                created_at_unix_ms: 2,
            })
            .unwrap();
        let caller = CallerContext {
            session_id: Some(SourcedString {
                value: "session-a".to_string(),
                source: "test".to_string(),
            }),
            ..CallerContext::default()
        };
        let mut request = chat_request("unit-model", "hello");
        let miss = evaluate_request_policies_with_cache(&mut request, &cfg, &caller, Some(&cache));
        assert_eq!(miss.alert_count, 0);

        cache
            .add(PolicyCacheEventInput {
                kind: "tool_call".to_string(),
                key: "shell:ls".to_string(),
                scope: HashMap::from([("session_id".to_string(), "session-a".to_string())]),
                value: Map::new(),
                created_at_unix_ms: 3,
            })
            .unwrap();
        let hit = evaluate_request_policies_with_cache(&mut request, &cfg, &caller, Some(&cache));
        assert_eq!(hit.alert_count, 1);
        assert_eq!(hit.actions[0]["history_count"], 2);
    }
}
