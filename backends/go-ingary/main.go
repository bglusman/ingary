package main

import (
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
	mu       sync.RWMutex
	receipts []Receipt
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

	s := &server{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", s.handleModels)
	mux.HandleFunc("/v1/chat/completions", s.handleChatCompletions)
	mux.HandleFunc("/v1/synthetic/simulate", s.handleSyntheticSimulate)
	mux.HandleFunc("/v1/receipts", s.handleReceipts)
	mux.HandleFunc("/v1/receipts/", s.handleReceiptByID)
	mux.HandleFunc("/admin/providers", s.handleProviders)
	mux.HandleFunc("/admin/synthetic-models", s.handleAdminSyntheticModels)

	log.Printf("go-ingary mock listening on http://%s", addr)
	if err := http.ListenAndServe(addr, requestLogger(mux)); err != nil {
		log.Fatal(err)
	}
}

func (s *server) handleModels(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data": []map[string]string{
			{"id": syntheticModel, "object": "model", "owned_by": "ingary"},
			{"id": syntheticPrefix + syntheticModel, "object": "model", "owned_by": "ingary"},
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
	model, err := normalizeModel(req.Model)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "unknown_model")
		return
	}
	if len(req.Messages) == 0 {
		writeError(w, http.StatusBadRequest, "messages must not be empty", "invalid_request", "missing_messages")
		return
	}

	caller := extractCaller(r, req.Metadata)
	estimate := estimatePromptTokens(req.Messages)
	selected := selectProviderModel(estimate)
	receipt := s.recordReceipt(true, model, caller, req, estimate, selected, "completed")

	w.Header().Set("X-Ingary-Receipt-Id", receipt.ReceiptID)
	w.Header().Set("X-Ingary-Selected-Model", selected)
	if req.Stream {
		writeMockStream(w, req.Model, selected, estimate)
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
				"content": fmt.Sprintf("Mock Ingary response routed to %s for %s. Estimated prompt tokens: %d.", selected, model, estimate),
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
	model, err := normalizeModel(body.Request.Model)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "invalid_request", "unknown_model")
		return
	}
	if len(body.Request.Messages) == 0 {
		writeError(w, http.StatusBadRequest, "request.messages must not be empty", "invalid_request", "missing_messages")
		return
	}

	caller := extractCaller(r, body.Request.Metadata)
	estimate := estimatePromptTokens(body.Request.Messages)
	selected := selectProviderModel(estimate)
	receipt := s.recordReceipt(false, model, caller, body.Request, estimate, selected, "simulated")
	writeJSON(w, http.StatusOK, map[string]any{"receipt": receipt})
}

func (s *server) handleReceipts(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	query := r.URL.Query()
	limit := parseLimit(query.Get("limit"))

	s.mu.RLock()
	defer s.mu.RUnlock()

	summaries := make([]ReceiptSummary, 0, min(limit, len(s.receipts)))
	for i := len(s.receipts) - 1; i >= 0 && len(summaries) < limit; i-- {
		receipt := s.receipts[i]
		if !matchesReceiptFilters(receipt, query.Get("model"), query.Get("consuming_agent_id"), query.Get("consuming_user_id"), query.Get("session_id"), query.Get("run_id"), query.Get("status")) {
			continue
		}
		summaries = append(summaries, receiptSummary(receipt))
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

	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, receipt := range s.receipts {
		if receipt.ReceiptID == id {
			writeJSON(w, http.StatusOK, receipt)
			return
		}
	}
	writeError(w, http.StatusNotFound, "receipt not found", "not_found", "receipt_not_found")
}

func (s *server) handleProviders(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": providers()})
}

func (s *server) handleAdminSyntheticModels(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": []map[string]any{syntheticModelRecord()}})
}

func (s *server) recordReceipt(callProvider bool, model string, caller CallerContext, req ChatCompletionRequest, estimate int, selected string, status string) Receipt {
	receiptID := "rcpt_" + randomHex(8)
	request := map[string]any{
		"model":                   req.Model,
		"normalized_model":        model,
		"estimated_prompt_tokens": estimate,
		"stream":                  req.Stream,
		"message_count":           len(req.Messages),
	}
	decision := map[string]any{
		"dispatcher":              "prompt_length_context_window",
		"selected_model":          selected,
		"estimated_prompt_tokens": estimate,
		"rule":                    "use local/qwen-coder at or below 32768 estimated prompt tokens; otherwise use managed/kimi-k2.6",
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
		"receipt_recorded_at": time.Now().UTC().Format(time.RFC3339),
	}

	receipt := Receipt{
		ReceiptSchema:    "v1",
		ReceiptID:        receiptID,
		RunID:            sourcedValue(caller.RunID),
		SyntheticModel:   model,
		SyntheticVersion: modelVersion,
		Caller:           caller,
		Request:          request,
		Decision:         decision,
		Attempts:         attempts,
		Final:            final,
	}

	s.mu.Lock()
	s.receipts = append(s.receipts, receipt)
	s.mu.Unlock()
	return receipt
}

func syntheticModelRecord() map[string]any {
	return map[string]any{
		"id":               syntheticModel,
		"active_version":   modelVersion,
		"description":      "Mock coding assistant synthetic model with prompt-length dispatch.",
		"public_namespace": "flat",
		"route_graph": map[string]any{
			"root": "dispatcher.prompt_length",
			"nodes": []map[string]any{
				{"id": "dispatcher.prompt_length", "type": "dispatcher", "targets": []string{"local.qwen_coder", "managed.kimi_k26"}},
				{"id": "local.qwen_coder", "type": "concrete_model", "provider_id": "local", "upstream_model_id": "qwen-coder", "context_window": 32768},
				{"id": "managed.kimi_k26", "type": "concrete_model", "provider_id": "managed", "upstream_model_id": "kimi-k2.6", "context_window": 262144},
			},
		},
		"stream_policy": map[string]any{
			"mode":          "buffered_horizon",
			"buffer_tokens": 256,
			"rules": []map[string]any{{
				"name":   "mock_noop",
				"action": "pass",
			}},
		},
	}
}

func providers() []map[string]string {
	return []map[string]string{
		{"id": "local", "kind": "mock", "base_url": "http://localhost/mock/local", "credential_owner": "provider", "health": "ok"},
		{"id": "managed", "kind": "mock", "base_url": "http://localhost/mock/managed", "credential_owner": "ingary", "health": "ok"},
	}
}

func normalizeModel(model string) (string, error) {
	model = strings.TrimSpace(model)
	if model == "" {
		return "", errors.New("model is required")
	}
	model = strings.TrimPrefix(model, syntheticPrefix)
	if model != syntheticModel {
		return "", fmt.Errorf("unknown synthetic model %q", model)
	}
	return model, nil
}

func selectProviderModel(estimatedPromptTokens int) string {
	if estimatedPromptTokens <= 32768 {
		return "local/qwen-coder"
	}
	return "managed/kimi-k2.6"
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

func matchesReceiptFilters(receipt Receipt, model string, agentID string, userID string, sessionID string, runID string, status string) bool {
	if model != "" {
		normalized, err := normalizeModel(model)
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
