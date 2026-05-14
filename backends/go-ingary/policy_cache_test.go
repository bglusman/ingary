package main

import (
	"sort"
	"testing"

	"hegel.dev/go/hegel"
)

func TestPolicyCacheEvictsOldestEntriesDeterministically(t *testing.T) {
	hegel.Test(t, func(ht *hegel.T) {
		capacity := hegel.Draw(ht, hegel.Integers(1, 20))
		timestamps := hegel.Draw(ht, hegel.Lists(hegel.Integers[int64](0, 50)).MaxSize(80))
		cache := NewMemoryPolicyCache(PolicyCacheConfig{MaxEntries: capacity, RecentLimit: capacity})

		type inserted struct {
			sequence  uint64
			createdAt int64
		}
		var insertedEvents []inserted
		for _, timestamp := range timestamps {
			event, err := cache.Add(PolicyCacheEventInput{
				Kind:            "tool_call",
				Key:             "shell:ls",
				Scope:           map[string]string{"session_id": "session-a"},
				CreatedAtUnixMS: timestamp,
			})
			if err != nil {
				ht.Fatalf("add policy cache event: %v", err)
			}
			insertedEvents = append(insertedEvents, inserted{sequence: event.Sequence, createdAt: timestamp})
		}

		sort.SliceStable(insertedEvents, func(i, j int) bool {
			if insertedEvents[i].createdAt == insertedEvents[j].createdAt {
				return insertedEvents[i].sequence < insertedEvents[j].sequence
			}
			return insertedEvents[i].createdAt < insertedEvents[j].createdAt
		})
		if len(insertedEvents) > capacity {
			insertedEvents = insertedEvents[len(insertedEvents)-capacity:]
		}
		expected := map[uint64]bool{}
		for _, event := range insertedEvents {
			expected[event.sequence] = true
		}

		recent := cache.Recent(PolicyCacheFilter{Kind: "tool_call", Key: "shell:ls", Scope: map[string]string{"session_id": "session-a"}}, capacity)
		if len(recent) != len(expected) {
			ht.Fatalf("recent count=%d, want %d", len(recent), len(expected))
		}
		for _, event := range recent {
			if !expected[event.Sequence] {
				ht.Fatalf("event sequence %d survived eviction unexpectedly; expected survivors=%v", event.Sequence, expected)
			}
		}
	}, hegel.WithTestCases(80))
}

func TestHistoryThresholdPolicyReadsOnlyConfiguredScope(t *testing.T) {
	cfg := testConfig()
	cfg.Governance = []GovernanceExample{{
		ID:         "repeat-tool",
		Kind:       "history_threshold",
		Action:     "escalate",
		CacheKind:  "tool_call",
		CacheKey:   "shell:ls",
		CacheScope: "session_id",
		Threshold:  2,
		Severity:   "warning",
	}}
	cache := NewMemoryPolicyCache(PolicyCacheConfig{MaxEntries: 8, RecentLimit: 8})
	_, _ = cache.Add(PolicyCacheEventInput{Kind: "tool_call", Key: "shell:ls", Scope: map[string]string{"session_id": "session-a"}})
	_, _ = cache.Add(PolicyCacheEventInput{Kind: "tool_call", Key: "shell:ls", Scope: map[string]string{"session_id": "session-b"}})
	req := chatRequest("unit-model", "hello")

	miss := evaluateRequestPoliciesWithCache(&req, cfg, CallerContext{SessionID: &SourcedString{Value: "session-a", Source: "test"}}, cache)
	if miss.AlertCount != 0 {
		t.Fatalf("alerted with only one matching session event: %+v", miss)
	}

	_, _ = cache.Add(PolicyCacheEventInput{Kind: "tool_call", Key: "shell:ls", Scope: map[string]string{"session_id": "session-a"}})
	hit := evaluateRequestPoliciesWithCache(&req, cfg, CallerContext{SessionID: &SourcedString{Value: "session-a", Source: "test"}}, cache)
	if hit.AlertCount != 1 {
		t.Fatalf("alert_count=%d, want 1", hit.AlertCount)
	}
	if got := hit.Actions[0]["history_count"]; got != 2 {
		t.Fatalf("history_count=%v, want 2", got)
	}
}
