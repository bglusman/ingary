import {
  modelSummaries,
  models,
  providers,
  receiptSummaries,
  receipts,
  simulateWithMocks,
} from "./mockData";
import type {
  Provider,
  Receipt,
  ReceiptFilters,
  ReceiptSummary,
  SimulationRequest,
  SimulationResult,
  SyntheticModel,
  SyntheticModelSummary,
} from "./types";

export const API_BASE_URL = "http://127.0.0.1:8787";

type ApiStatus = "api" | "mock";

let lastStatus: ApiStatus = "mock";

export function getApiStatus(): ApiStatus {
  return lastStatus;
}

async function requestJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
    ...init,
  });

  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}`);
  }

  lastStatus = "api";
  return response.json() as Promise<T>;
}

async function withMockFallback<T>(apiCall: () => Promise<T>, mockValue: () => T): Promise<T> {
  try {
    return await apiCall();
  } catch {
    lastStatus = "mock";
    return mockValue();
  }
}

export function listSyntheticModels(): Promise<SyntheticModelSummary[]> {
  return withMockFallback(
    async () => {
      const result = await requestJson<{ data: SyntheticModelSummary[] }>("/v1/synthetic/models");
      return result.data;
    },
    () => modelSummaries,
  );
}

export function listAdminSyntheticModels(): Promise<SyntheticModel[]> {
  return withMockFallback(
    async () => {
      const result = await requestJson<{ data: SyntheticModel[] }>("/admin/synthetic-models");
      return result.data;
    },
    () => models,
  );
}

export function listProviders(): Promise<Provider[]> {
  return withMockFallback(
    async () => {
      const result = await requestJson<{ data: Provider[] }>("/admin/providers");
      return result.data;
    },
    () => providers,
  );
}

export function searchReceipts(filters: ReceiptFilters): Promise<ReceiptSummary[]> {
  const query = new URLSearchParams();
  Object.entries(filters).forEach(([key, value]) => {
    if (value !== undefined && value !== "") query.set(key, String(value));
  });

  return withMockFallback(
    async () => {
      const result = await requestJson<{ data: ReceiptSummary[] }>(`/v1/receipts?${query.toString()}`);
      return result.data;
    },
    () =>
      receiptSummaries.filter((receipt) => {
        if (filters.model && receipt.synthetic_model !== filters.model) return false;
        if (filters.consuming_agent_id && receipt.caller.consuming_agent_id?.value !== filters.consuming_agent_id) return false;
        if (filters.consuming_user_id && receipt.caller.consuming_user_id?.value !== filters.consuming_user_id) return false;
        if (filters.session_id && receipt.caller.session_id?.value !== filters.session_id) return false;
        if (filters.run_id && receipt.caller.run_id?.value !== filters.run_id) return false;
        if (filters.status && receipt.status !== filters.status) return false;
        return true;
      }),
  );
}

export function getReceipt(receiptId: string): Promise<Receipt> {
  return withMockFallback(
    () => requestJson<Receipt>(`/v1/receipts/${encodeURIComponent(receiptId)}`),
    () => receipts.find((receipt) => receipt.receipt_id === receiptId) ?? receipts[0],
  );
}

export function simulateRoute(request: SimulationRequest, headers: Record<string, string>): Promise<SimulationResult> {
  return withMockFallback(
    () =>
      requestJson<SimulationResult>("/v1/synthetic/simulate", {
        method: "POST",
        headers,
        body: JSON.stringify(request),
      }),
    () => simulateWithMocks(request),
  );
}
