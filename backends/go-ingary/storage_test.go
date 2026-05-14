package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMemoryReceiptStoreListsNewestFirstAndFilters(t *testing.T) {
	store := NewMemoryReceiptStore()
	cfg := defaultTestConfig()
	receipts := []Receipt{
		testReceipt("rcpt_1", "agent-a", "user-a", "session-a", "run-a", "completed", "local/qwen-coder"),
		testReceipt("rcpt_2", "agent-b", "user-b", "session-b", "run-b", "simulated", "managed/kimi-k2.6"),
		testReceipt("rcpt_3", "agent-a", "user-c", "session-c", "run-c", "completed", "local/qwen-coder"),
	}
	for _, receipt := range receipts {
		if err := store.InsertReceipt(receipt); err != nil {
			t.Fatalf("insert receipt: %v", err)
		}
	}

	all, err := store.ListReceiptSummaries(ReceiptFilter{Config: cfg}, 10)
	if err != nil {
		t.Fatalf("list receipts: %v", err)
	}
	if got, want := receiptIDs(all), []string{"rcpt_3", "rcpt_2", "rcpt_1"}; !equalStrings(got, want) {
		t.Fatalf("receipt order = %v, want %v", got, want)
	}

	filtered, err := store.ListReceiptSummaries(ReceiptFilter{
		ConsumingAgentID: "agent-a",
		Status:           "completed",
		Config:           cfg,
	}, 10)
	if err != nil {
		t.Fatalf("list filtered receipts: %v", err)
	}
	if got, want := receiptIDs(filtered), []string{"rcpt_3", "rcpt_1"}; !equalStrings(got, want) {
		t.Fatalf("filtered receipt ids = %v, want %v", got, want)
	}
}

func TestMemoryReceiptStoreOwnsReceiptCopies(t *testing.T) {
	store := NewMemoryReceiptStore()
	receipt := testReceipt("rcpt_copy", "agent-a", "user-a", "session-a", "run-a", "completed", "local/qwen-coder")
	if err := store.InsertReceipt(receipt); err != nil {
		t.Fatalf("insert receipt: %v", err)
	}

	receipt.Decision["selected_model"] = "mutated/after-insert"
	stored, ok, err := store.GetReceipt("rcpt_copy")
	if err != nil {
		t.Fatalf("get receipt: %v", err)
	}
	if !ok {
		t.Fatal("receipt was not found")
	}
	if got := stringFromMap(stored.Decision, "selected_model"); got != "local/qwen-coder" {
		t.Fatalf("stored selected_model = %q, want original value", got)
	}

	stored.Decision["selected_model"] = "mutated/after-get"
	storedAgain, ok, err := store.GetReceipt("rcpt_copy")
	if err != nil {
		t.Fatalf("get receipt again: %v", err)
	}
	if !ok {
		t.Fatal("receipt was not found on second get")
	}
	if got := stringFromMap(storedAgain.Decision, "selected_model"); got != "local/qwen-coder" {
		t.Fatalf("stored selected_model after get mutation = %q, want original value", got)
	}
}

func TestMemoryReceiptStoreClearReceipts(t *testing.T) {
	store := NewMemoryReceiptStore()
	if err := store.InsertReceipt(testReceipt("rcpt_1", "agent-a", "user-a", "session-a", "run-a", "completed", "local/qwen-coder")); err != nil {
		t.Fatalf("insert receipt: %v", err)
	}
	if err := store.ClearReceipts(); err != nil {
		t.Fatalf("clear receipts: %v", err)
	}
	summaries, err := store.ListReceiptSummaries(ReceiptFilter{Config: defaultTestConfig()}, 10)
	if err != nil {
		t.Fatalf("list receipts after clear: %v", err)
	}
	if len(summaries) != 0 {
		t.Fatalf("receipt count after clear = %d, want 0", len(summaries))
	}
}

func TestMemoryReceiptStoreHealth(t *testing.T) {
	health := NewMemoryReceiptStore().Health()
	if got, want := health["kind"], "memory"; got != want {
		t.Fatalf("kind = %v, want %v", got, want)
	}
	if got, want := health["contract_version"], "storage-contract-v0"; got != want {
		t.Fatalf("contract_version = %v, want %v", got, want)
	}
	capabilities, ok := health["capabilities"].(map[string]any)
	if !ok {
		t.Fatalf("capabilities has type %T, want map[string]any", health["capabilities"])
	}
	if capabilities["durable"] != false {
		t.Fatalf("durable capability = %v, want false", capabilities["durable"])
	}
}

func TestOpenAICompatibleProviderUsesCredentialEnvAndUpstreamModel(t *testing.T) {
	t.Setenv("INGARY_TEST_PROVIDER_KEY", "test-secret")
	var sawAuthorization string
	var sawModel string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("request path = %q, want /v1/chat/completions", r.URL.Path)
		}
		sawAuthorization = r.Header.Get("Authorization")
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode provider request: %v", err)
		}
		sawModel, _ = body["model"].(string)
		writeJSON(w, http.StatusOK, map[string]any{
			"choices": []map[string]any{{
				"message": map[string]string{"content": "provider content"},
			}},
		})
	}))
	defer server.Close()

	content, err := completeWithOpenAICompatible(RouteTarget{
		Model:           "openai/gpt-test",
		ContextWindow:   128000,
		ProviderKind:    "openai-compatible",
		ProviderBaseURL: server.URL + "/v1",
		CredentialEnv:   "INGARY_TEST_PROVIDER_KEY",
	}, ChatCompletionRequest{
		Model:    "coding-balanced",
		Messages: []ChatMessage{{Role: "user", Content: "hello"}},
	})
	if err != nil {
		t.Fatalf("complete with provider: %v", err)
	}
	if content != "provider content" {
		t.Fatalf("content = %q, want provider content", content)
	}
	if sawAuthorization != "Bearer test-secret" {
		t.Fatalf("authorization header = %q, want bearer token", sawAuthorization)
	}
	if sawModel != "gpt-test" {
		t.Fatalf("provider model = %q, want upstream model suffix", sawModel)
	}
}

func TestProviderMetadataReportsCredentialSourceWithoutValue(t *testing.T) {
	providers := providersForConfig(TestConfig{
		SyntheticModel: syntheticModel,
		Version:        modelVersion,
		Targets: []RouteTarget{{
			Model:           "openai/gpt-test",
			ContextWindow:   128000,
			ProviderKind:    "openai-compatible",
			ProviderBaseURL: "https://example.com/v1",
			CredentialEnv:   "INGARY_TEST_PROVIDER_KEY",
		}},
	})
	if len(providers) != 1 {
		t.Fatalf("provider count = %d, want 1", len(providers))
	}
	if providers[0]["credential_source"] != "env" {
		t.Fatalf("credential_source = %v, want env", providers[0]["credential_source"])
	}
	if _, ok := providers[0]["credential_env"]; ok {
		t.Fatal("provider metadata must not expose credential env names")
	}
	if _, ok := providers[0]["credential"]; ok {
		t.Fatal("provider metadata must not expose credential values")
	}
}

func testReceipt(receiptID, agentID, userID, sessionID, runID, status, selectedModel string) Receipt {
	return Receipt{
		ReceiptSchema:    "v1",
		ReceiptID:        receiptID,
		RunID:            runID,
		SyntheticModel:   syntheticModel,
		SyntheticVersion: modelVersion,
		Caller: CallerContext{
			ConsumingAgentID: &SourcedString{Value: agentID, Source: "header"},
			ConsumingUserID:  &SourcedString{Value: userID, Source: "header"},
			SessionID:        &SourcedString{Value: sessionID, Source: "header"},
			RunID:            &SourcedString{Value: runID, Source: "header"},
		},
		Decision: map[string]any{"selected_model": selectedModel},
		Attempts: []map[string]any{{
			"provider_model": selectedModel,
			"status":         status,
		}},
		Final: map[string]any{"status": status},
	}
}

func receiptIDs(summaries []ReceiptSummary) []string {
	ids := make([]string, 0, len(summaries))
	for _, summary := range summaries {
		ids = append(ids, summary.ReceiptID)
	}
	return ids
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}
