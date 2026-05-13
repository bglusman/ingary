use std::{
    collections::HashMap,
    net::SocketAddr,
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
        .route("/v1/synthetic/simulate", post(simulate))
        .route("/v1/receipts", get(list_receipts))
        .route("/v1/receipts/:receipt_id", get(get_receipt))
        .route("/admin/providers", get(list_providers))
        .route("/admin/synthetic-models", get(list_synthetic_models))
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
        .with_state(state)
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[derive(Clone, Default)]
struct AppState {
    receipts: Arc<RwLock<Vec<Receipt>>>,
}

async fn list_models() -> Json<Value> {
    Json(json!({
        "object": "list",
        "data": [
            {"id": SYNTHETIC_MODEL_ID, "object": "model", "owned_by": "ingary"},
            {"id": format!("ingary/{SYNTHETIC_MODEL_ID}"), "object": "model", "owned_by": "ingary"}
        ]
    }))
}

async fn chat_completions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<ChatCompletionRequest>,
) -> Result<Response, ApiError> {
    let normalized_model = normalize_model(request.model.as_deref()).ok_or_else(|| {
        ApiError::bad_request("model must be coding-balanced or ingary/coding-balanced")
    })?;
    let caller = caller_from(headers.clone(), request.metadata.as_ref());
    let decision = select_route(&request);
    let receipt = build_receipt(
        caller,
        normalized_model.clone(),
        Some(request.clone()),
        decision.clone(),
        "completed",
    );

    state.receipts.write().await.push(receipt.clone());

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
    Json(request): Json<SimulationRequest>,
) -> Result<Json<Value>, ApiError> {
    let model = request
        .model
        .as_deref()
        .or(request.request.model.as_deref());
    let normalized_model = normalize_model(model).ok_or_else(|| {
        ApiError::bad_request("model must be coding-balanced or ingary/coding-balanced")
    })?;
    let caller = caller_from(headers, request.request.metadata.as_ref());
    let decision = select_route(&request.request);
    let receipt = build_receipt(
        caller,
        normalized_model,
        Some(request.request),
        decision,
        "simulated",
    );

    state.receipts.write().await.push(receipt.clone());
    Ok(Json(json!({ "receipt": receipt })))
}

async fn list_receipts(
    State(state): State<AppState>,
    Query(query): Query<ReceiptQuery>,
) -> Json<Value> {
    let limit = query.limit.unwrap_or(50).clamp(1, 500);
    let receipts = state.receipts.read().await;
    let data: Vec<ReceiptSummary> = receipts
        .iter()
        .rev()
        .filter(|receipt| query.matches(receipt))
        .take(limit)
        .map(ReceiptSummary::from)
        .collect();

    Json(json!({ "data": data }))
}

async fn get_receipt(
    State(state): State<AppState>,
    Path(receipt_id): Path<String>,
) -> Result<Json<Receipt>, ApiError> {
    let receipts = state.receipts.read().await;
    receipts
        .iter()
        .find(|receipt| receipt.receipt_id == receipt_id)
        .cloned()
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

async fn list_synthetic_models() -> Json<Value> {
    Json(json!({ "data": [synthetic_model_record()] }))
}

fn synthetic_model_record() -> Value {
    json!({
        "id": SYNTHETIC_MODEL_ID,
        "public_model_id": SYNTHETIC_MODEL_ID,
        "active_version": SYNTHETIC_VERSION,
        "description": "Mock dispatcher that selects a local coding model for short prompts and a managed long-context model for larger prompts.",
        "public_namespace": "prefixed",
        "route_type": "dispatcher",
        "status": "active",
        "traffic_24h": 0,
        "fallback_rate": 0.0,
        "stream_trigger_count_24h": 0,
        "route_graph": {
            "root": "prompt-length-dispatcher",
            "nodes": [
                {
                    "id": "prompt-length-dispatcher",
                    "type": "dispatcher",
                    "targets": [LOCAL_MODEL, MANAGED_MODEL],
                    "strategy": "estimated_prompt_length"
                },
                {
                    "id": LOCAL_MODEL,
                    "type": "concrete_model",
                    "provider_id": "local",
                    "upstream_model_id": "qwen-coder",
                    "context_window": LOCAL_CONTEXT_WINDOW
                },
                {
                    "id": MANAGED_MODEL,
                    "type": "concrete_model",
                    "provider_id": "managed",
                    "upstream_model_id": "kimi-k2.6",
                    "context_window": MANAGED_CONTEXT_WINDOW
                }
            ]
        },
        "stream_policy": {
            "mode": "pass_through",
            "buffer_tokens": 0,
            "rules": []
        }
    })
}

fn normalize_model(model: Option<&str>) -> Option<String> {
    match model {
        Some(SYNTHETIC_MODEL_ID) => Some(SYNTHETIC_MODEL_ID.to_string()),
        Some(value) if value == format!("ingary/{SYNTHETIC_MODEL_ID}") => {
            Some(SYNTHETIC_MODEL_ID.to_string())
        }
        _ => None,
    }
}

fn select_route(request: &ChatCompletionRequest) -> RouteDecision {
    let estimated_prompt_tokens = estimate_prompt_tokens(&request.messages);
    let selected_model = if estimated_prompt_tokens <= LOCAL_CONTEXT_WINDOW {
        LOCAL_MODEL
    } else {
        MANAGED_MODEL
    };

    RouteDecision {
        selected_model: selected_model.to_string(),
        estimated_prompt_tokens,
        reason: if selected_model == LOCAL_MODEL {
            "estimated prompt fits local context window".to_string()
        } else {
            "estimated prompt exceeds local context window".to_string()
        },
    }
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
) -> Receipt {
    let receipt_id = format!("rcpt_{}", Uuid::new_v4());
    let run_id = caller.run_id.as_ref().map(|run_id| run_id.value.clone());
    Receipt {
        receipt_schema: "v1".to_string(),
        receipt_id,
        run_id,
        synthetic_model,
        synthetic_version: SYNTHETIC_VERSION.to_string(),
        caller,
        request: request.map(|request| serde_json::to_value(request).unwrap_or(Value::Null)),
        decision: json!({
            "strategy": "estimated_prompt_length",
            "estimated_prompt_tokens": decision.estimated_prompt_tokens,
            "selected_model": decision.selected_model,
            "reason": decision.reason,
            "threshold_tokens": LOCAL_CONTEXT_WINDOW
        }),
        attempts: vec![json!({
            "provider_id": decision.selected_model.split('/').next().unwrap_or("mock"),
            "model": decision.selected_model,
            "status": status,
            "mock": true
        })],
        final_result: json!({
            "status": status,
            "selected_model": decision.selected_model,
            "stream_trigger_count": 0
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
    reason: String,
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
            normalize_model(Some(model)).as_deref() == Some(&receipt.synthetic_model)
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
