package main

import (
	"encoding/json"
	"errors"
	"sync"
)

type ReceiptFilter struct {
	Model            string
	ConsumingAgentID string
	ConsumingUserID  string
	SessionID        string
	RunID            string
	Status           string
	Config           TestConfig
}

type ReceiptStore interface {
	Health() map[string]any
	InsertReceipt(receipt Receipt) error
	GetReceipt(receiptID string) (Receipt, bool, error)
	ListReceiptSummaries(filter ReceiptFilter, limit int) ([]ReceiptSummary, error)
	ClearReceipts() error
}

type MemoryReceiptStore struct {
	mu       sync.RWMutex
	receipts []Receipt
}

func NewMemoryReceiptStore() *MemoryReceiptStore {
	return &MemoryReceiptStore{}
}

func (s *MemoryReceiptStore) Health() map[string]any {
	return map[string]any{
		"kind":              "memory",
		"contract_version":  "storage-contract-v0",
		"migration_version": 1,
		"read_health":       "ok",
		"write_health":      "ok",
		"capabilities": map[string]any{
			"durable":            false,
			"transactional":      true,
			"concurrent_writers": false,
			"json_queries":       true,
			"event_replay":       true,
			"time_range_indexes": false,
			"retention_jobs":     false,
		},
	}
}

func (s *MemoryReceiptStore) InsertReceipt(receipt Receipt) error {
	if receipt.ReceiptID == "" {
		return errors.New("receipt_id must not be empty")
	}
	stored, err := cloneReceipt(receipt)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.receipts = append(s.receipts, stored)
	return nil
}

func (s *MemoryReceiptStore) GetReceipt(receiptID string) (Receipt, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, receipt := range s.receipts {
		if receipt.ReceiptID == receiptID {
			cloned, err := cloneReceipt(receipt)
			if err != nil {
				return Receipt{}, false, err
			}
			return cloned, true, nil
		}
	}
	return Receipt{}, false, nil
}

func (s *MemoryReceiptStore) ListReceiptSummaries(filter ReceiptFilter, limit int) ([]ReceiptSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	summaries := make([]ReceiptSummary, 0, min(limit, len(s.receipts)))
	for i := len(s.receipts) - 1; i >= 0 && len(summaries) < limit; i-- {
		receipt := s.receipts[i]
		if !matchesReceiptFilters(receipt, filter.Model, filter.ConsumingAgentID, filter.ConsumingUserID, filter.SessionID, filter.RunID, filter.Status, filter.Config) {
			continue
		}
		summaries = append(summaries, receiptSummary(receipt))
	}
	return summaries, nil
}

func (s *MemoryReceiptStore) ClearReceipts() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.receipts = nil
	return nil
}

func cloneReceipt(receipt Receipt) (Receipt, error) {
	encoded, err := json.Marshal(receipt)
	if err != nil {
		return Receipt{}, err
	}
	var cloned Receipt
	if err := json.Unmarshal(encoded, &cloned); err != nil {
		return Receipt{}, err
	}
	return cloned, nil
}
