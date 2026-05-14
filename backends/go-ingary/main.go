package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultAddr     = "127.0.0.1:8787"
	syntheticModel  = "coding-balanced"
	syntheticPrefix = "ingary/"
	modelVersion    = "2026-05-13.mock"
)

type server struct {
	mu      sync.RWMutex
	config  TestConfig
	storage ReceiptStore
}

type TestConfig struct {
	SyntheticModel   string              `json:"synthetic_model"`
	Version          string              `json:"version,omitempty"`
	Targets          []RouteTarget       `json:"targets"`
	StreamRules      []StreamRule        `json:"stream_rules,omitempty"`
	PromptTransforms PromptTransforms    `json:"prompt_transforms,omitempty"`
	StructuredOutput *StructuredOutput   `json:"structured_output,omitempty"`
	Governance       []GovernanceExample `json:"governance,omitempty"`
}

type RouteTarget struct {
	Model           string `json:"model"`
	ContextWindow   int    `json:"context_window"`
	ProviderKind    string `json:"provider_kind,omitempty"`
	ProviderBaseURL string `json:"provider_base_url,omitempty"`
}

type StreamRule struct {
	ID      string `json:"id"`
	Pattern string `json:"pattern"`
	Action  string `json:"action"`
}

type PromptTransforms struct {
	Preamble   string `json:"preamble,omitempty"`
	Postscript string `json:"postscript,omitempty"`
}

type StructuredOutput struct {
	Mode        string         `json:"mode,omitempty"`
	Schema      map[string]any `json:"schema,omitempty"`
	RepairTries int            `json:"repair_tries,omitempty"`
}

type GovernanceExample struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"`
	Action   string `json:"action"`
	Contains string `json:"contains,omitempty"`
	Message  string `json:"message,omitempty"`
	Severity string `json:"severity,omitempty"`
	Reminder string `json:"reminder,omitempty"`
}

type ChatCompletionRequest struct {
	Model    string         `json:"model"`
	Messages []ChatMessage  `json:"messages"`
	Stream   bool           `json:"stream,omitempty"`
	Metadata map[string]any `json:"metadata,omitempty"`
}

type ChatMessage struct {
	Role    string `json:"role"`
	Content any    `json:"content,omitempty"`
	Name    string `json:"name,omitempty"`
}

type SourcedString struct {
	Value  string `json:"value"`
	Source string `json:"source"`
}

type CallerContext struct {
	TenantID         *SourcedString `json:"tenant_id,omitempty"`
	ApplicationID    *SourcedString `json:"application_id,omitempty"`
	ConsumingAgentID *SourcedString `json:"consuming_agent_id,omitempty"`
	ConsumingUserID  *SourcedString `json:"consuming_user_id,omitempty"`
	SessionID        *SourcedString `json:"session_id,omitempty"`
	RunID            *SourcedString `json:"run_id,omitempty"`
	Tags             []string       `json:"tags,omitempty"`
	ClientRequestID  *SourcedString `json:"client_request_id,omitempty"`
}

type Receipt struct {
	ReceiptSchema    string           `json:"receipt_schema"`
	ReceiptID        string           `json:"receipt_id"`
	RunID            string           `json:"run_id,omitempty"`
	SyntheticModel   string           `json:"synthetic_model"`
	SyntheticVersion string           `json:"synthetic_version"`
	Caller           CallerContext    `json:"caller"`
	Request          map[string]any   `json:"request,omitempty"`
	Decision         map[string]any   `json:"decision"`
	Attempts         []map[string]any `json:"attempts"`
	Final            map[string]any   `json:"final"`
}

type ReceiptSummary struct {
	ReceiptID          string        `json:"receipt_id"`
	SyntheticModel     string        `json:"synthetic_model"`
	SyntheticVersion   string        `json:"synthetic_version"`
	SelectedModel      string        `json:"selected_model,omitempty"`
	Status             string        `json:"status"`
	StreamTriggerCount int           `json:"stream_trigger_count"`
	Caller             CallerContext `json:"caller"`
}

func main() {
	addr := os.Getenv("INGARY_ADDR")
	if addr == "" {
		addr = defaultAddr
	}

	s := newServer(defaultTestConfig(), NewMemoryReceiptStore())
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", s.handleModels)
	mux.HandleFunc("/v1/chat/completions", s.handleChatCompletions)
	mux.HandleFunc("/v1/synthetic/models", s.handleSyntheticModelSummaries)
	mux.HandleFunc("/v1/synthetic/simulate", s.handleSyntheticSimulate)
	mux.HandleFunc("/v1/receipts", s.handleReceipts)
	mux.HandleFunc("/v1/receipts/", s.handleReceiptByID)
	mux.HandleFunc("/admin/providers", s.handleProviders)
	mux.HandleFunc("/admin/storage", s.handleStorage)
	mux.HandleFunc("/admin/synthetic-models", s.handleAdminSyntheticModels)
	mux.HandleFunc("/__test/config", s.handleTestConfig)

	log.Printf("go-ingary mock listening on http://%s", addr)
	if err := http.ListenAndServe(addr, requestLogger(corsMiddleware(mux))); err != nil {
		log.Fatal(err)
	}
}

func newServer(cfg TestConfig, storage ReceiptStore) *server {
	if cfg.SyntheticModel == "" {
		cfg = defaultTestConfig()
	}
	if storage == nil {
		storage = NewMemoryReceiptStore()
	}
	return &server{config: cfg, storage: storage}
}

func (s *server) handleModels(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	cfg := s.currentConfig()
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data": []map[string]string{
			{"id": cfg.SyntheticModel, "object": "model", "owned_by": "ingary"},
			{"id": syntheticPrefix + cfg.SyntheticModel, "object": "model", "owned_by": "ingary"},
		},
	})
}

func (s *server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	var req ChatCompletionRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "invalid_json")
		return
	}
	cfg := s.currentConfig()
	model, err := normalizeModel(req.Model, cfg)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "unknown_model")
		return
	}
	if len(req.Messages) == 0 {
		writeError(w, http.StatusBadRequest, "messages must not be empty", "invalid_request", "missing_messages")
		return
	}

	caller := extractCaller(r, req.Metadata)
	req = applyPromptTransforms(req, cfg)
	policy := evaluateRequestPolicies(&req, cfg)
	estimate := estimatePromptTokens(req.Messages)
	selected, skipped := selectProviderModel(estimate, cfg)
	receipt, err := s.recordReceipt(true, model, caller, req, estimate, selected, skipped, "completed", cfg, policy)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to build receipt", "server_error", "receipt_failed")
		return
	}

	w.Header().Set("X-Ingary-Receipt-Id", receipt.ReceiptID)
	w.Header().Set("X-Ingary-Selected-Model", selected)
	if req.Stream {
		if err := s.storage.InsertReceipt(receipt); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to record receipt", "server_error", "receipt_store_failed")
			return
		}
		writeMockStream(w, req.Model, selected, estimate)
		return
	}

	content, providerStatus, providerLatency, providerErr := completeSelectedModel(selected, req, cfg)
	if content == "" {
		content = mockContent(selected, model, estimate, cfg)
	}
	receipt.Attempts[0]["status"] = providerStatus
	receipt.Attempts[0]["latency_ms"] = providerLatency
	receipt.Attempts[0]["provider_error"] = errorString(providerErr)
	receipt.Final["status"] = providerStatus
	receipt.Final["provider_error"] = errorString(providerErr)
	if err := s.storage.InsertReceipt(receipt); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to record receipt", "server_error", "receipt_store_failed")
		return
	}

	now := time.Now().Unix()
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      "chatcmpl_" + receipt.ReceiptID,
		"object":  "chat.completion",
		"created": now,
		"model":   req.Model,
		"choices": []map[string]any{{
			"index": 0,
			"message": map[string]string{
				"role":    "assistant",
				"content": content,
			},
			"finish_reason": "stop",
		}},
		"usage": map[string]int{
			"prompt_tokens":     estimate,
			"completion_tokens": 18,
			"total_tokens":      estimate + 18,
		},
	})
}

func (s *server) handleSyntheticModelSummaries(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": []map[string]any{syntheticModelRecord(s.currentConfig())}})
}

func (s *server) handleSyntheticSimulate(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	var body struct {
		Model   string                `json:"model,omitempty"`
		Request ChatCompletionRequest `json:"request"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "invalid_json")
		return
	}
	if body.Model != "" {
		body.Request.Model = body.Model
	}
	cfg := s.currentConfig()
	model, err := normalizeModel(body.Request.Model, cfg)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "unknown_model")
		return
	}
	if len(body.Request.Messages) == 0 {
		writeError(w, http.StatusBadRequest, "request.messages must not be empty", "invalid_request", "missing_messages")
		return
	}

	caller := extractCaller(r, body.Request.Metadata)
	body.Request = applyPromptTransforms(body.Request, cfg)
	policy := evaluateRequestPolicies(&body.Request, cfg)
	estimate := estimatePromptTokens(body.Request.Messages)
	selected, skipped := selectProviderModel(estimate, cfg)
	receipt, err := s.recordReceipt(false, model, caller, body.Request, estimate, selected, skipped, "simulated", cfg, policy)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to build receipt", "server_error", "receipt_failed")
		return
	}
	if err := s.storage.InsertReceipt(receipt); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to record receipt", "server_error", "receipt_store_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"receipt": receipt})
}

func (s *server) handleReceipts(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	query := r.URL.Query()
	limit := parseLimit(query.Get("limit"))
	cfg := s.currentConfig()
	summaries, err := s.storage.ListReceiptSummaries(ReceiptFilter{
		Model:            query.Get("model"),
		ConsumingAgentID: query.Get("consuming_agent_id"),
		ConsumingUserID:  query.Get("consuming_user_id"),
		SessionID:        query.Get("session_id"),
		RunID:            query.Get("run_id"),
		Status:           query.Get("status"),
		Config:           cfg,
	}, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to list receipts", "server_error", "receipt_store_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": summaries})
}

func (s *server) handleReceiptByID(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/v1/receipts/")
	if id == "" || strings.Contains(id, "/") {
		http.NotFound(w, r)
		return
	}

	receipt, ok, err := s.storage.GetReceipt(id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to get receipt", "server_error", "receipt_store_failed")
		return
	}
	if ok {
		writeJSON(w, http.StatusOK, receipt)
		return
	}
	writeError(w, http.StatusNotFound, "receipt not found", "not_found", "receipt_not_found")
}

func (s *server) handleProviders(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": providersForConfig(s.currentConfig())})
}

func (s *server) handleStorage(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, s.storage.Health())
}

func (s *server) handleAdminSyntheticModels(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": []map[string]any{syntheticModelRecord(s.currentConfig())}})
}

func (s *server) handleTestConfig(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}
	var cfg TestConfig
	if err := decodeJSON(r, &cfg); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "invalid_json")
		return
	}
	if err := validateTestConfig(cfg); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "invalid_test_config")
		return
	}
	if cfg.Version == "" {
		cfg.Version = modelVersion
	}
	if err := s.storage.ClearReceipts(); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to clear receipts", "server_error", "receipt_store_failed")
		return
	}
	s.mu.Lock()
	s.config = cfg
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "synthetic_model": cfg.SyntheticModel, "targets": cfg.Targets})
}

func (s *server) currentConfig() TestConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.config.SyntheticModel == "" {
		return defaultTestConfig()
	}
	return s.config
}

func (s *server) recordReceipt(callProvider bool, model string, caller CallerContext, req ChatCompletionRequest, estimate int, selected string, skipped []map[string]any, status string, cfg TestConfig, policy PolicyResult) (Receipt, error) {
	receiptID := "rcpt_" + randomHex(8)
	request := map[string]any{
		"model":                   req.Model,
		"normalized_model":        model,
		"estimated_prompt_tokens": estimate,
		"stream":                  req.Stream,
		"message_count":           len(req.Messages),
		"prompt_transforms":       cfg.PromptTransforms,
		"structured_output":       cfg.StructuredOutput,
	}
	decision := map[string]any{
		"dispatcher":              "prompt_length_context_window",
		"selected_model":          selected,
		"estimated_prompt_tokens": estimate,
		"skipped":                 skipped,
		"rule":                    "select the smallest configured context window that fits the estimated prompt",
		"governance":              cfg.Governance,
		"policy_actions":          policy.Actions,
	}
	attempts := []map[string]any{{
		"provider_model":  selected,
		"status":          status,
		"mock":            true,
		"called_provider": callProvider,
	}}
	final := map[string]any{
		"status":              status,
		"selected_model":      selected,
		"alert_count":         policy.AlertCount,
		"receipt_recorded_at": time.Now().UTC().Format(time.RFC3339),
	}
	if len(policy.Events) > 0 {
		final["events"] = policy.Events
	}

	receipt := Receipt{
		ReceiptSchema:    "v1",
		ReceiptID:        receiptID,
		RunID:            sourcedValue(caller.RunID),
		SyntheticModel:   model,
		SyntheticVersion: cfg.Version,
		Caller:           caller,
		Request:          request,
		Decision:         decision,
		Attempts:         attempts,
		Final:            final,
	}

	return receipt, nil
}

func syntheticModelRecord(cfg TestConfig) map[string]any {
	nodes := []map[string]any{{"id": "dispatcher.prompt_length", "type": "dispatcher"}}
	targetIDs := make([]string, 0, len(cfg.Targets))
	for _, target := range cfg.Targets {
		id := strings.ReplaceAll(target.Model, "/", ".")
		targetIDs = append(targetIDs, id)
		nodes = append(nodes, map[string]any{"id": id, "type": "concrete_model", "provider_id": strings.Split(target.Model, "/")[0], "upstream_model_id": target.Model, "context_window": target.ContextWindow})
	}
	nodes[0]["targets"] = targetIDs
	return map[string]any{
		"id":                       cfg.SyntheticModel,
		"public_model_id":          cfg.SyntheticModel,
		"active_version":           cfg.Version,
		"description":              "Mock coding assistant synthetic model with prompt-length dispatch.",
		"public_namespace":         "flat",
		"route_type":               "dispatcher",
		"status":                   "active",
		"traffic_24h":              0,
		"fallback_rate":            0.0,
		"stream_trigger_count_24h": 0,
		"route_graph": map[string]any{
			"root":  "dispatcher.prompt_length",
			"nodes": nodes,
		},
		"stream_policy": map[string]any{
			"mode":          "buffered_horizon",
			"buffer_tokens": 256,
			"rules":         cfg.StreamRules,
		},
		"prompt_transforms": cfg.PromptTransforms,
		"structured_output": cfg.StructuredOutput,
		"governance":        cfg.Governance,
	}
}

func providers() []map[string]string {
	return providersForConfig(defaultTestConfig())
}

func providersForConfig(cfg TestConfig) []map[string]string {
	seen := map[string]bool{}
	var providers []map[string]string
	for _, target := range cfg.Targets {
		id := strings.Split(target.Model, "/")[0]
		if seen[id] {
			continue
		}
		seen[id] = true
		kind := strings.TrimSpace(target.ProviderKind)
		if kind == "" {
			kind = "mock"
		}
		baseURL := strings.TrimSpace(target.ProviderBaseURL)
		if baseURL == "" {
			if id == "ollama" {
				kind = "ollama"
				baseURL = getenvDefault("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
			} else {
				baseURL = "mock://" + id
			}
		}
		providers = append(providers, map[string]string{"id": id, "kind": kind, "base_url": baseURL, "credential_owner": "ingary", "health": "ok"})
	}
	return providers
}

func defaultTestConfig() TestConfig {
	return TestConfig{
		SyntheticModel: syntheticModel,
		Version:        modelVersion,
		Targets: []RouteTarget{
			{Model: "local/qwen-coder", ContextWindow: 32768},
			{Model: "managed/kimi-k2.6", ContextWindow: 262144},
		},
		StreamRules: []StreamRule{{ID: "mock_noop", Pattern: "", Action: "pass"}},
		Governance: []GovernanceExample{
			{ID: "json_object", Kind: "structured_output", Action: "validate_or_block"},
			{ID: "xml_well_formed", Kind: "structured_output", Action: "validate_or_block"},
			{ID: "prompt_transforms", Kind: "request_transform", Action: "prepend_append_messages"},
		},
	}
}

func validateTestConfig(cfg TestConfig) error {
	if strings.TrimSpace(cfg.SyntheticModel) == "" {
		return errors.New("synthetic_model must not be empty")
	}
	if strings.Contains(cfg.SyntheticModel, "/") {
		return errors.New("synthetic_model must be unprefixed")
	}
	if len(cfg.Targets) == 0 {
		return errors.New("targets must not be empty")
	}
	seen := map[string]bool{}
	for _, target := range cfg.Targets {
		if strings.TrimSpace(target.Model) == "" {
			return errors.New("target model must not be empty")
		}
		if target.ContextWindow <= 0 {
			return fmt.Errorf("target %s context_window must be positive", target.Model)
		}
		if seen[target.Model] {
			return fmt.Errorf("duplicate target %s", target.Model)
		}
		seen[target.Model] = true
	}
	return nil
}

func normalizeModel(model string, cfg TestConfig) (string, error) {
	model = strings.TrimSpace(model)
	if model == "" {
		return "", errors.New("model is required")
	}
	model = strings.TrimPrefix(model, syntheticPrefix)
	if model != cfg.SyntheticModel {
		return "", fmt.Errorf("unknown synthetic model %q", model)
	}
	return model, nil
}

func selectProviderModel(estimatedPromptTokens int, cfg TestConfig) (string, []map[string]any) {
	targets := append([]RouteTarget(nil), cfg.Targets...)
	sort.Slice(targets, func(i, j int) bool {
		if targets[i].ContextWindow == targets[j].ContextWindow {
			return targets[i].Model < targets[j].Model
		}
		return targets[i].ContextWindow < targets[j].ContextWindow
	})
	var skipped []map[string]any
	for _, target := range targets {
		if target.ContextWindow >= estimatedPromptTokens {
			return target.Model, skipped
		}
		skipped = append(skipped, map[string]any{"target": target.Model, "reason": "context_window_too_small", "context_window": target.ContextWindow})
	}
	if len(targets) == 0 {
		return "unconfigured/no-target", skipped
	}
	return targets[len(targets)-1].Model, skipped
}

func applyPromptTransforms(req ChatCompletionRequest, cfg TestConfig) ChatCompletionRequest {
	messages := append([]ChatMessage(nil), req.Messages...)
	if text := strings.TrimSpace(cfg.PromptTransforms.Preamble); text != "" {
		messages = append([]ChatMessage{{Role: "system", Content: text, Name: "ingary_preamble"}}, messages...)
	}
	if text := strings.TrimSpace(cfg.PromptTransforms.Postscript); text != "" {
		messages = append(messages, ChatMessage{Role: "system", Content: text, Name: "ingary_postscript"})
	}
	req.Messages = messages
	return req
}

type PolicyResult struct {
	Actions    []map[string]any
	Events     []map[string]any
	AlertCount int
}

func evaluateRequestPolicies(req *ChatCompletionRequest, cfg TestConfig) PolicyResult {
	var result PolicyResult
	text := strings.ToLower(requestText(req.Messages))
	for _, rule := range cfg.Governance {
		if rule.Kind != "request_guard" && rule.Kind != "request_transform" && rule.Kind != "receipt_annotation" {
			continue
		}
		needle := strings.ToLower(strings.TrimSpace(rule.Contains))
		if needle == "" || !strings.Contains(text, needle) {
			continue
		}
		message := strings.TrimSpace(rule.Message)
		if message == "" {
			message = "request policy matched"
		}
		severity := strings.TrimSpace(rule.Severity)
		if severity == "" {
			severity = "info"
		}
		action := map[string]any{
			"rule_id":  rule.ID,
			"kind":     rule.Kind,
			"action":   rule.Action,
			"matched":  true,
			"message":  message,
			"severity": severity,
		}
		result.Actions = append(result.Actions, action)
		switch rule.Action {
		case "escalate":
			result.AlertCount++
			result.Events = append(result.Events, map[string]any{
				"type":     "policy.alert",
				"rule_id":  rule.ID,
				"message":  message,
				"severity": severity,
			})
		case "inject_reminder_and_retry", "transform":
			reminder := strings.TrimSpace(rule.Reminder)
			if reminder == "" {
				reminder = message
			}
			req.Messages = append(req.Messages, ChatMessage{Role: "system", Name: "ingary_policy_reminder", Content: reminder})
			action["reminder_injected"] = true
		case "annotate":
			result.Events = append(result.Events, map[string]any{
				"type":     "policy.annotated",
				"rule_id":  rule.ID,
				"message":  message,
				"severity": severity,
			})
		}
	}
	return result
}

func requestText(messages []ChatMessage) string {
	var builder strings.Builder
	for _, message := range messages {
		builder.WriteString(message.Role)
		builder.WriteByte('\n')
		builder.WriteString(contentString(message.Content))
		builder.WriteByte('\n')
	}
	return builder.String()
}

func completeSelectedModel(selected string, req ChatCompletionRequest, cfg TestConfig) (string, string, int64, error) {
	started := time.Now()
	target := targetByModel(selected, cfg)
	status := "completed"
	if target == nil || providerKind(*target) == "mock" {
		return "", status, time.Since(started).Milliseconds(), nil
	}
	switch providerKind(*target) {
	case "ollama":
		content, err := completeWithOllama(*target, req)
		if err != nil {
			status = "provider_error"
		}
		return content, status, time.Since(started).Milliseconds(), err
	default:
		return "", "provider_unsupported", time.Since(started).Milliseconds(), fmt.Errorf("unsupported provider kind %q", providerKind(*target))
	}
}

func targetByModel(model string, cfg TestConfig) *RouteTarget {
	for _, target := range cfg.Targets {
		if target.Model == model {
			copy := target
			return &copy
		}
	}
	return nil
}

func providerKind(target RouteTarget) string {
	if target.ProviderKind != "" {
		return strings.TrimSpace(target.ProviderKind)
	}
	if strings.HasPrefix(target.Model, "ollama/") {
		return "ollama"
	}
	return "mock"
}

func completeWithOllama(target RouteTarget, req ChatCompletionRequest) (string, error) {
	model := strings.TrimPrefix(target.Model, "ollama/")
	baseURL := strings.TrimRight(target.ProviderBaseURL, "/")
	if baseURL == "" {
		baseURL = getenvDefault("OLLAMA_BASE_URL", "http://127.0.0.1:11434")
	}
	messages := make([]map[string]any, 0, len(req.Messages))
	for _, message := range req.Messages {
		messages = append(messages, map[string]any{
			"role":    message.Role,
			"content": contentString(message.Content),
		})
	}
	body := map[string]any{"model": model, "messages": messages, "stream": false}
	encoded, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	client := &http.Client{Timeout: 180 * time.Second}
	resp, err := client.Post(baseURL+"/api/chat", "application/json", bytes.NewReader(encoded))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("ollama returned %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	var parsed struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return "", err
	}
	return parsed.Message.Content, nil
}

func mockContent(selected string, model string, estimate int, cfg TestConfig) string {
	var builder strings.Builder
	builder.WriteString(fmt.Sprintf("Mock Ingary response routed to %s for %s. Estimated prompt tokens: %d.", selected, model, estimate))
	if cfg.StructuredOutput != nil {
		switch cfg.StructuredOutput.Mode {
		case "json_object":
			return fmt.Sprintf(`{"route":"%s","synthetic_model":"%s","estimated_prompt_tokens":%d}`, selected, model, estimate)
		case "xml":
			return fmt.Sprintf("<route selected_model=%q synthetic_model=%q estimated_prompt_tokens=%q />", selected, model, strconv.Itoa(estimate))
		}
	}
	return builder.String()
}

func estimatePromptTokens(messages []ChatMessage) int {
	chars := 0
	for _, msg := range messages {
		chars += len(msg.Role)
		switch content := msg.Content.(type) {
		case string:
			chars += len(content)
		case nil:
		default:
			encoded, err := json.Marshal(content)
			if err == nil {
				chars += len(encoded)
			}
		}
	}
	if chars == 0 {
		return 1
	}
	return (chars + 3) / 4
}

func extractCaller(r *http.Request, metadata map[string]any) CallerContext {
	return CallerContext{
		TenantID:         sourcedHeaderOrMetadata(r, metadata, "X-Ingary-Tenant-Id", "tenant_id"),
		ApplicationID:    sourcedHeaderOrMetadata(r, metadata, "X-Ingary-Application-Id", "application_id"),
		ConsumingAgentID: sourcedHeaderOrMetadata(r, metadata, "X-Ingary-Agent-Id", "consuming_agent_id"),
		ConsumingUserID:  sourcedHeaderOrMetadata(r, metadata, "X-Ingary-User-Id", "consuming_user_id"),
		SessionID:        sourcedHeaderOrMetadata(r, metadata, "X-Ingary-Session-Id", "session_id"),
		RunID:            sourcedHeaderOrMetadata(r, metadata, "X-Ingary-Run-Id", "run_id"),
		ClientRequestID:  sourcedHeaderOrMetadata(r, metadata, "X-Client-Request-Id", "client_request_id"),
		Tags:             metadataTags(metadata),
	}
}

func sourcedHeaderOrMetadata(r *http.Request, metadata map[string]any, header string, key string) *SourcedString {
	if value := strings.TrimSpace(r.Header.Get(header)); value != "" {
		return &SourcedString{Value: value, Source: "header"}
	}
	if value := metadataString(metadata, key); value != "" {
		return &SourcedString{Value: value, Source: "body_metadata"}
	}
	return nil
}

func metadataString(metadata map[string]any, key string) string {
	if metadata == nil {
		return ""
	}
	value, ok := metadata[key]
	if !ok {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case fmt.Stringer:
		return strings.TrimSpace(typed.String())
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func metadataTags(metadata map[string]any) []string {
	if metadata == nil {
		return nil
	}
	raw, ok := metadata["tags"]
	if !ok {
		return nil
	}
	var tags []string
	switch typed := raw.(type) {
	case []any:
		for _, item := range typed {
			if tag := strings.TrimSpace(fmt.Sprint(item)); tag != "" {
				tags = append(tags, tag)
			}
		}
	case []string:
		for _, item := range typed {
			if tag := strings.TrimSpace(item); tag != "" {
				tags = append(tags, tag)
			}
		}
	case string:
		for _, item := range strings.Split(typed, ",") {
			if tag := strings.TrimSpace(item); tag != "" {
				tags = append(tags, tag)
			}
		}
	}
	sort.Strings(tags)
	return tags
}

func contentString(content any) string {
	switch typed := content.(type) {
	case string:
		return typed
	case nil:
		return ""
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return fmt.Sprint(typed)
		}
		return string(encoded)
	}
}

func errorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func getenvDefault(key string, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func receiptSummary(receipt Receipt) ReceiptSummary {
	return ReceiptSummary{
		ReceiptID:          receipt.ReceiptID,
		SyntheticModel:     receipt.SyntheticModel,
		SyntheticVersion:   receipt.SyntheticVersion,
		SelectedModel:      stringFromMap(receipt.Decision, "selected_model"),
		Status:             stringFromMap(receipt.Final, "status"),
		StreamTriggerCount: 0,
		Caller:             receipt.Caller,
	}
}

func matchesReceiptFilters(receipt Receipt, model string, agentID string, userID string, sessionID string, runID string, status string, cfg TestConfig) bool {
	if model != "" {
		normalized, err := normalizeModel(model, cfg)
		if err != nil || receipt.SyntheticModel != normalized {
			return false
		}
	}
	if agentID != "" && sourcedValue(receipt.Caller.ConsumingAgentID) != agentID {
		return false
	}
	if userID != "" && sourcedValue(receipt.Caller.ConsumingUserID) != userID {
		return false
	}
	if sessionID != "" && sourcedValue(receipt.Caller.SessionID) != sessionID {
		return false
	}
	if runID != "" && sourcedValue(receipt.Caller.RunID) != runID {
		return false
	}
	if status != "" && stringFromMap(receipt.Final, "status") != status {
		return false
	}
	return true
}

func writeMockStream(w http.ResponseWriter, model string, selected string, estimate int) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	flusher, _ := w.(http.Flusher)
	chunks := []string{
		"Mock Ingary stream ",
		"routed to " + selected + " ",
		fmt.Sprintf("for %s with %d estimated prompt tokens.", model, estimate),
	}
	for i, chunk := range chunks {
		payload := map[string]any{
			"id":      "chatcmpl_stream_mock",
			"object":  "chat.completion.chunk",
			"created": time.Now().Unix(),
			"model":   model,
			"choices": []map[string]any{{
				"index": i,
				"delta": map[string]string{"content": chunk},
			}},
		}
		encoded, _ := json.Marshal(payload)
		fmt.Fprintf(w, "data: %s\n\n", encoded)
		if flusher != nil {
			flusher.Flush()
		}
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}

func decodeJSON(r *http.Request, dst any) error {
	defer r.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.UseNumber()
	if err := decoder.Decode(dst); err != nil {
		return err
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("write json failed: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string, typ string, code string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]string{
			"message": message,
			"type":    typ,
			"code":    code,
		},
	})
}

func requireMethod(w http.ResponseWriter, r *http.Request, method string) bool {
	if r.Method == method {
		return true
	}
	w.Header().Set("Allow", method)
	writeError(w, http.StatusMethodNotAllowed, "method not allowed", "invalid_request", "method_not_allowed")
	return false
}

func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Ingary-Tenant-Id, X-Ingary-Application-Id, X-Ingary-Agent-Id, X-Ingary-User-Id, X-Ingary-Session-Id, X-Ingary-Run-Id, X-Client-Request-Id")
		w.Header().Set("Access-Control-Expose-Headers", "X-Ingary-Receipt-Id, X-Ingary-Selected-Model")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func parseLimit(raw string) int {
	if raw == "" {
		return 50
	}
	limit, err := strconv.Atoi(raw)
	if err != nil || limit < 1 {
		return 50
	}
	if limit > 500 {
		return 500
	}
	return limit
}

func randomHex(bytes int) string {
	buf := make([]byte, bytes)
	if _, err := rand.Read(buf); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(buf)
}

func stringFromMap(values map[string]any, key string) string {
	value, ok := values[key]
	if !ok {
		return ""
	}
	asString, _ := value.(string)
	return asString
}

func sourcedValue(value *SourcedString) string {
	if value == nil {
		return ""
	}
	return value.Value
}

func min(a int, b int) int {
	if a < b {
		return a
	}
	return b
}
