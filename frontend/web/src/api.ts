import type {
  Provider,
  Receipt,
  ReceiptFilters,
  ReceiptSummary,
  SimulationRequest,
  SimulationResult,
  StorageHealth,
  SyntheticModel,
  SyntheticModelSummary,
} from "./types";

export type BackendTarget = {
  id: string;
  label: string;
  baseUrl: string;
  note: string;
};

export const BACKENDS: BackendTarget[] = [
  { id: "go", label: "Go", baseUrl: "http://127.0.0.1:8787", note: "dynamic config + property fuzz" },
  { id: "rust", label: "Rust", baseUrl: "http://127.0.0.1:8797", note: "typed storage trait" },
  { id: "elixir", label: "Elixir", baseUrl: "http://127.0.0.1:8791", note: "receipt filters + storage metadata" },
];

const STORAGE_KEY = "ingary.apiBaseUrl";

type ApiStatus = "api" | "offline";

let lastStatus: ApiStatus = "offline";
let apiBaseUrl = readInitialBaseUrl();

export function getApiStatus(): ApiStatus {
  return lastStatus;
}

export function getApiBaseUrl(): string {
  return apiBaseUrl;
}

export function setApiBaseUrl(nextBaseUrl: string): void {
  apiBaseUrl = nextBaseUrl;
  lastStatus = "offline";
  window.localStorage.setItem(STORAGE_KEY, nextBaseUrl);
}

function readInitialBaseUrl(): string {
  return window.localStorage.getItem(STORAGE_KEY) ?? BACKENDS[0].baseUrl;
}

async function requestJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${apiBaseUrl}${path}`, {
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
    ...init,
  });

  if (!response.ok) {
    lastStatus = "offline";
    throw new Error(`${response.status} ${response.statusText}`);
  }

  lastStatus = "api";
  return response.json() as Promise<T>;
}

export function listSyntheticModels(): Promise<SyntheticModelSummary[]> {
  return requestJson<{ data: SyntheticModelSummary[] }>("/v1/synthetic/models").then((result) => result.data);
}

export function listAdminSyntheticModels(): Promise<SyntheticModel[]> {
  return requestJson<{ data: SyntheticModel[] }>("/admin/synthetic-models").then((result) => result.data);
}

export function listProviders(): Promise<Provider[]> {
  return requestJson<{ data: Provider[] }>("/admin/providers").then((result) => result.data);
}

export function listStorageHealth(): Promise<StorageHealth> {
  return requestJson<StorageHealth>("/admin/storage");
}

export function searchReceipts(filters: ReceiptFilters): Promise<ReceiptSummary[]> {
  const query = new URLSearchParams();
  Object.entries(filters).forEach(([key, value]) => {
    if (value !== undefined && value !== "") query.set(key, String(value));
  });

  return requestJson<{ data: ReceiptSummary[] }>(`/v1/receipts?${query.toString()}`).then((result) => result.data);
}

export function getReceipt(receiptId: string): Promise<Receipt> {
  return requestJson<Receipt>(`/v1/receipts/${encodeURIComponent(receiptId)}`);
}

export function simulateRoute(request: SimulationRequest, headers: Record<string, string>): Promise<SimulationResult> {
  return requestJson<SimulationResult>("/v1/synthetic/simulate", {
    method: "POST",
    headers,
    body: JSON.stringify(request),
  });
}
