package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNormalizeModelAcceptsFlatAndPrefixedIDs(t *testing.T) {
	cfg := testConfig()

	for _, model := range []string{"unit-model", "ingary/unit-model", "  ingary/unit-model  "} {
		got, err := normalizeModel(model, cfg)
		if err != nil {
			t.Fatalf("normalizeModel(%q): %v", model, err)
		}
		if got != "unit-model" {
			t.Fatalf("normalizeModel(%q) = %q, want unit-model", model, got)
		}
	}

	if _, err := normalizeModel("other-model", cfg); err == nil {
		t.Fatal("normalizeModel accepted an unknown model")
	}
}

func TestSelectProviderModelUsesSmallestContextWindowThatFits(t *testing.T) {
	cfg := testConfig()

	selected, skipped := selectProviderModel(2, cfg)
	if selected != "tiny/model" || len(skipped) != 0 {
		t.Fatalf("small prompt selected=%q skipped=%v, want tiny/model and no skipped targets", selected, skipped)
	}

	selected, skipped = selectProviderModel(20, cfg)
	if selected != "medium/model" {
		t.Fatalf("medium prompt selected=%q, want medium/model", selected)
	}
	if len(skipped) != 1 || skipped[0]["target"] != "tiny/model" {
		t.Fatalf("medium prompt skipped=%v, want tiny/model", skipped)
	}

	selected, skipped = selectProviderModel(500, cfg)
	if selected != "large/model" {
		t.Fatalf("oversized prompt selected=%q, want largest fallback", selected)
	}
	if len(skipped) != 3 {
		t.Fatalf("oversized prompt skipped %d targets, want 3", len(skipped))
	}
}

func TestApplyPromptTransformsAddsNamedSystemMessages(t *testing.T) {
	cfg := testConfig()
	cfg.PromptTransforms = PromptTransforms{
		Preamble:   "Use JSON.",
		Postscript: "Validate before answering.",
	}
	req := chatRequest("unit-model", "hello")

	transformed := applyPromptTransforms(req, cfg)

	if len(req.Messages) != 1 {
		t.Fatalf("original request was mutated; message count=%d", len(req.Messages))
	}
	if len(transformed.Messages) != 3 {
		t.Fatalf("transformed message count=%d, want 3", len(transformed.Messages))
	}
	if transformed.Messages[0].Name != "ingary_preamble" {
		t.Fatalf("first message name=%q, want ingary_preamble", transformed.Messages[0].Name)
	}
	if transformed.Messages[2].Name != "ingary_postscript" {
		t.Fatalf("last message name=%q, want ingary_postscript", transformed.Messages[2].Name)
	}
}

func TestEvaluateRequestPoliciesRecordsAlertAndInjectedReminder(t *testing.T) {
	cfg := testConfig()
	cfg.Governance = []GovernanceExample{
		{
			ID:       "ambiguous-success",
			Kind:     "request_guard",
			Action:   "escalate",
			Contains: "looks done",
			Message:  "completion claim needs artifact",
			Severity: "warning",
		},
		{
			ID:       "json-reminder",
			Kind:     "request_transform",
			Action:   "inject_reminder_and_retry",
			Contains: "return json",
			Reminder: "Return only valid JSON.",
		},
	}
	req := chatRequest("unit-model", "Looks done; return JSON for the caller")

	policy := evaluateRequestPolicies(&req, cfg)

	if policy.AlertCount != 1 {
		t.Fatalf("alert count=%d, want 1", policy.AlertCount)
	}
	if len(policy.Actions) != 2 {
		t.Fatalf("actions=%v, want two policy actions", policy.Actions)
	}
	if len(policy.Events) != 1 || policy.Events[0]["type"] != "policy.alert" {
		t.Fatalf("events=%v, want one policy.alert event", policy.Events)
	}
	if got := req.Messages[len(req.Messages)-1].Name; got != "ingary_policy_reminder" {
		t.Fatalf("last message name=%q, want ingary_policy_reminder", got)
	}
}

func TestValidateTestConfigRejectsInvalidRouteGraphs(t *testing.T) {
	cfg := testConfig()
	if err := validateTestConfig(cfg); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}

	cfg.SyntheticModel = "ingary/unit-model"
	if err := validateTestConfig(cfg); err == nil {
		t.Fatal("validateTestConfig accepted a prefixed synthetic model")
	}

	cfg = testConfig()
	cfg.Targets = append(cfg.Targets, RouteTarget{Model: "tiny/model", ContextWindow: 64})
	if err := validateTestConfig(cfg); err == nil {
		t.Fatal("validateTestConfig accepted duplicate targets")
	}
}

func TestChatCompletionEndpointRecordsCallerAndPolicyReceipt(t *testing.T) {
	s := newServer(testConfig(), NewMemoryReceiptStore())
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", s.handleChatCompletions)
	mux.HandleFunc("/v1/receipts/", s.handleReceiptByID)

	body := map[string]any{
		"model": "ingary/unit-model",
		"messages": []map[string]string{
			{"role": "user", "content": "Looks done; return JSON for the caller"},
		},
		"metadata": map[string]any{"consuming_agent_id": "body-agent"},
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(encoded))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Ingary-Agent-Id", "header-agent")
	resp := httptest.NewRecorder()

	mux.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("chat status=%d body=%s", resp.Code, resp.Body.String())
	}
	receiptID := resp.Header().Get("X-Ingary-Receipt-Id")
	if receiptID == "" {
		t.Fatal("missing receipt header")
	}

	getReq := httptest.NewRequest(http.MethodGet, "/v1/receipts/"+receiptID, nil)
	getResp := httptest.NewRecorder()
	mux.ServeHTTP(getResp, getReq)
	if getResp.Code != http.StatusOK {
		t.Fatalf("receipt status=%d body=%s", getResp.Code, getResp.Body.String())
	}

	var receipt Receipt
	if err := json.Unmarshal(getResp.Body.Bytes(), &receipt); err != nil {
		t.Fatalf("decode receipt: %v", err)
	}
	if receipt.Caller.ConsumingAgentID == nil || receipt.Caller.ConsumingAgentID.Value != "header-agent" {
		t.Fatalf("receipt caller=%+v, want header-agent precedence", receipt.Caller)
	}
	if got := intFromMap(receipt.Final, "alert_count"); got != 1 {
		t.Fatalf("alert_count=%d, want 1", got)
	}
}

func testConfig() TestConfig {
	return TestConfig{
		SyntheticModel: "unit-model",
		Version:        "unit-version",
		Targets: []RouteTarget{
			{Model: "tiny/model", ContextWindow: 8},
			{Model: "medium/model", ContextWindow: 32},
			{Model: "large/model", ContextWindow: 256},
		},
		Governance: []GovernanceExample{
			{
				ID:       "ambiguous-success",
				Kind:     "request_guard",
				Action:   "escalate",
				Contains: "looks done",
				Message:  "completion claim needs artifact",
				Severity: "warning",
			},
		},
	}
}

func chatRequest(model, content string) ChatCompletionRequest {
	return ChatCompletionRequest{
		Model: model,
		Messages: []ChatMessage{
			{Role: "user", Content: content},
		},
	}
}

func intFromMap(values map[string]any, key string) int {
	switch value := values[key].(type) {
	case int:
		return value
	case float64:
		return int(value)
	default:
		return 0
	}
}
