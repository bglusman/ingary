import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  BACKENDS,
  getApiStatus,
  getApiBaseUrl,
  getReceipt,
  listAdminSyntheticModels,
  listProviders,
  listStorageHealth,
  listSyntheticModels,
  searchReceipts,
  setApiBaseUrl,
  simulateRoute,
} from "./api";
import { sinks, storageProviders } from "./mockData";
import "./styles.css";
import type {
  CallerContext,
  Provider,
  Receipt,
  ReceiptFilters,
  ReceiptSummary,
  Sink,
  SimulationResult,
  StorageHealth,
  StorageProvider,
  SyntheticModel,
  SyntheticModelSummary,
} from "./types";

const navItems = ["Catalog", "Routes", "Simulator", "Receipts", "Providers", "Storage"] as const;
type View = (typeof navItems)[number];

function App() {
  const [view, setView] = useState<View>("Catalog");
  const [models, setModels] = useState<SyntheticModelSummary[]>([]);
  const [fullModels, setFullModels] = useState<SyntheticModel[]>([]);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [receipts, setReceipts] = useState<ReceiptSummary[]>([]);
  const [selectedReceipt, setSelectedReceipt] = useState<Receipt | null>(null);
  const [apiStatus, setApiStatus] = useState(getApiStatus());
  const [apiBaseUrl, setApiBaseUrlState] = useState(getApiBaseUrl());
  const [storageHealth, setStorageHealth] = useState<StorageHealth | null>(null);
  const [filters, setFilters] = useState<ReceiptFilters>({ limit: 50 });
  const [selectedModelId, setSelectedModelId] = useState("coding-balanced");
  const selectedModel = fullModels.find((model) => model.id === selectedModelId) ?? fullModels[0];

  useEffect(() => {
    loadBackendData();
  }, [apiBaseUrl]);

  async function loadBackendData() {
    Promise.all([listSyntheticModels(), listAdminSyntheticModels(), listProviders(), searchReceipts({ limit: 50 }), listStorageHealth()]).then(
      ([modelRows, fullModelRows, providerRows, receiptRows, storage]) => {
        setModels(modelRows);
        setFullModels(fullModelRows);
        setProviders(providerRows);
        setReceipts(receiptRows);
        setSelectedReceipt(null);
        setStorageHealth(storage);
        setSelectedModelId(fullModelRows[0]?.id ?? "coding-balanced");
        setApiStatus(getApiStatus());
      },
    );
  }

  function selectBackend(baseUrl: string) {
    setApiBaseUrl(baseUrl);
    setApiBaseUrlState(baseUrl);
  }

  async function applyReceiptFilters(nextFilters = filters) {
    setFilters(nextFilters);
    const rows = await searchReceipts(nextFilters);
    setReceipts(rows);
    setSelectedReceipt(rows[0] ? await getReceipt(rows[0].receipt_id) : null);
    setApiStatus(getApiStatus());
  }

  return (
    <main className="shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="mark">SM</span>
          <div>
            <strong>Synthetic Models</strong>
            <span>Prototype console</span>
          </div>
        </div>
        <nav>
          {navItems.map((item) => (
            <button className={view === item ? "active" : ""} key={item} onClick={() => setView(item)}>
              {item}
            </button>
          ))}
        </nav>
        <div className="sidebarFooter">
          <span>Source</span>
          <strong>{apiStatus === "api" ? "API" : "Local mock"}</strong>
          <span>Backend</span>
          <strong>{BACKENDS.find((backend) => backend.baseUrl === apiBaseUrl)?.label ?? "Custom"}</strong>
        </div>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div>
            <p className="eyebrow">OpenAI-compatible control plane</p>
            <h1>{view}</h1>
          </div>
          <div className="backendPicker">
            <label>
              Backend
              <select value={apiBaseUrl} onChange={(event) => selectBackend(event.target.value)}>
                {BACKENDS.map((backend) => (
                  <option value={backend.baseUrl} key={backend.id}>
                    {backend.label} - {backend.baseUrl}
                  </option>
                ))}
              </select>
            </label>
            <div className="endpoint">{apiBaseUrl}</div>
          </div>
        </header>

        {view === "Catalog" && <Catalog models={models} />}
        {view === "Routes" && (
          <Routes fullModels={fullModels} providers={providers} selectedModelId={selectedModelId} setSelectedModelId={setSelectedModelId} />
        )}
        {view === "Simulator" && <Simulator models={fullModels} onStatus={() => setApiStatus(getApiStatus())} />}
        {view === "Receipts" && (
          <Receipts
            filters={filters}
            receipts={receipts}
            selectedReceipt={selectedReceipt}
            setFilters={setFilters}
            applyFilters={applyReceiptFilters}
            selectReceipt={async (receiptId) => {
              const receipt = await getReceipt(receiptId);
              setSelectedReceipt(receipt);
              setApiStatus(getApiStatus());
            }}
          />
        )}
        {view === "Providers" && <Providers providers={providers} models={fullModels} selectedModel={selectedModel} />}
        {view === "Storage" && <Storage storageProviders={storageProviders} storageHealth={storageHealth} sinks={sinks} receipts={receipts} />}
      </section>
    </main>
  );
}

function Catalog({ models }: { models: SyntheticModelSummary[] }) {
  const [agentFilter, setAgentFilter] = useState("");
  const [userFilter, setUserFilter] = useState("");
  const filtered = useMemo(() => {
    return models.filter((model) => {
      const filterText = `${model.id} ${model.public_model_id} ${model.status}`.toLowerCase();
      return filterText.includes(agentFilter.toLowerCase()) && filterText.includes(userFilter.toLowerCase());
    });
  }, [agentFilter, models, userFilter]);

  return (
    <section className="panel">
      <div className="panelHeader">
        <div>
          <h2>Model catalog</h2>
          <p>Public synthetic model names, active versions, and recent operational indicators.</p>
        </div>
        <div className="filterBar">
          <label>
            Agent filter
            <input value={agentFilter} onChange={(event) => setAgentFilter(event.target.value)} placeholder="agent, route, status" />
          </label>
          <label>
            User filter
            <input value={userFilter} onChange={(event) => setUserFilter(event.target.value)} placeholder="user-facing search" />
          </label>
        </div>
      </div>
      <div className="tableWrap">
        <table>
          <thead>
            <tr>
              <th>Public model</th>
              <th>Version</th>
              <th>Route</th>
              <th>Status</th>
              <th>24h traffic</th>
              <th>Fallback</th>
              <th>Stream triggers</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((model) => (
              <tr key={model.id}>
                <td>
                  <strong>{model.public_model_id ?? model.id}</strong>
                  <span>{model.id}</span>
                </td>
                <td>{model.active_version}</td>
                <td>{model.route_type}</td>
                <td>
                  <Badge value={model.status} />
                </td>
                <td>{model.traffic_24h?.toLocaleString()}</td>
                <td>{formatPercent(model.fallback_rate)}</td>
                <td>{model.stream_trigger_count_24h ?? 0}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function Routes({
  fullModels,
  providers,
  selectedModelId,
  setSelectedModelId,
}: {
  fullModels: SyntheticModel[];
  providers: Provider[];
  selectedModelId: string;
  setSelectedModelId: (id: string) => void;
}) {
  const model = fullModels.find((candidate) => candidate.id === selectedModelId) ?? fullModels[0];
  const providerMap = new Map(providers.map((provider) => [provider.id, provider]));

  if (!model) return <Empty message="No synthetic models loaded." />;

  return (
    <section className="split">
      <div className="panel">
        <div className="panelHeader compact">
          <div>
            <h2>Route graph</h2>
            <p>{model.description}</p>
          </div>
          <select value={model.id} onChange={(event) => setSelectedModelId(event.target.value)}>
            {fullModels.map((candidate) => (
              <option value={candidate.id} key={candidate.id}>
                {candidate.id}
              </option>
            ))}
          </select>
        </div>
        <div className="graph">
          {model.route_graph.nodes.map((node) => (
            <div className={`node ${node.id === model.route_graph.root ? "root" : ""}`} key={node.id}>
              <div>
                <Badge value={node.type} />
                <strong>{node.id}</strong>
              </div>
              {node.targets && <span>Targets: {node.targets.join(", ")}</span>}
              {node.provider_id && (
                <span>
                  Provider: {node.provider_id} ({providerMap.get(node.provider_id)?.health ?? "unknown"})
                </span>
              )}
              {node.upstream_model_id && <span>Upstream: {node.upstream_model_id}</span>}
              {node.context_window && <span>Context: {node.context_window.toLocaleString()} tokens</span>}
            </div>
          ))}
        </div>
      </div>
      <div className="panel">
        <h2>Stream policy</h2>
        <div className="kv">
          <span>Mode</span>
          <strong>{model.stream_policy?.mode ?? "pass_through"}</strong>
          <span>Buffer</span>
          <strong>{model.stream_policy?.buffer_tokens ?? 0} tokens</strong>
          <span>Rules</span>
          <strong>{model.stream_policy?.rules?.length ?? 0}</strong>
        </div>
        <pre>{JSON.stringify(model.stream_policy?.rules ?? [], null, 2)}</pre>
      </div>
    </section>
  );
}

function Simulator({ models, onStatus }: { models: SyntheticModel[]; onStatus: () => void }) {
  const [model, setModel] = useState("coding-balanced");
  const [agent, setAgent] = useState("agent-codex");
  const [user, setUser] = useState("user-platform");
  const [prompt, setPrompt] = useState("Review this patch and choose the smallest context route that fits.");
  const [stream, setStream] = useState(true);
  const [result, setResult] = useState<SimulationResult | null>(null);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    const response = await simulateRoute(
      {
        model,
        request: {
          model,
          stream,
          messages: [{ role: "user", content: prompt }],
          metadata: { agent_id: agent, user_id: user },
        },
      },
      {
        "X-Ingary-Agent-Id": agent,
        "X-Ingary-User-Id": user,
        "X-Ingary-Session-Id": "sim-session",
        "X-Ingary-Run-Id": "sim-run",
      },
    );
    setResult(response);
    onStatus();
  }

  return (
    <section className="split">
      <form className="panel formPanel" onSubmit={submit}>
        <div className="panelHeader compact">
          <div>
            <h2>Route simulator</h2>
            <p>Posts to /v1/synthetic/simulate when available, otherwise runs the local planner mock.</p>
          </div>
        </div>
        <label>
          Synthetic model
          <select value={model} onChange={(event) => setModel(event.target.value)}>
            {models.map((candidate) => (
              <option value={candidate.id} key={candidate.id}>
                {candidate.id}
              </option>
            ))}
          </select>
        </label>
        <div className="twoCol">
          <label>
            Agent
            <input value={agent} onChange={(event) => setAgent(event.target.value)} />
          </label>
          <label>
            User
            <input value={user} onChange={(event) => setUser(event.target.value)} />
          </label>
        </div>
        <label>
          Prompt
          <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} rows={9} />
        </label>
        <label className="check">
          <input type="checkbox" checked={stream} onChange={(event) => setStream(event.target.checked)} />
          Stream request
        </label>
        <button className="primary" type="submit">
          Simulate route
        </button>
      </form>
      <div className="panel">
        <h2>Simulation receipt</h2>
        {result ? <ReceiptDetail receipt={result.receipt} /> : <Empty message="Run a simulation to inspect route decisions." />}
      </div>
    </section>
  );
}

function Receipts({
  filters,
  receipts,
  selectedReceipt,
  setFilters,
  applyFilters,
  selectReceipt,
}: {
  filters: ReceiptFilters;
  receipts: ReceiptSummary[];
  selectedReceipt: Receipt | null;
  setFilters: (filters: ReceiptFilters) => void;
  applyFilters: () => void;
  selectReceipt: (receiptId: string) => void;
}) {
  return (
    <section className="split receiptsSplit">
      <div className="panel">
        <div className="panelHeader compact">
          <div>
            <h2>Receipt explorer</h2>
            <p>Filter route decisions by synthetic model, status, and caller provenance.</p>
          </div>
        </div>
        <div className="filterGrid">
          <input value={filters.model ?? ""} onChange={(event) => setFilters({ ...filters, model: event.target.value })} placeholder="model" />
          <input
            value={filters.consuming_agent_id ?? ""}
            onChange={(event) => setFilters({ ...filters, consuming_agent_id: event.target.value })}
            placeholder="agent id"
          />
          <input
            value={filters.consuming_user_id ?? ""}
            onChange={(event) => setFilters({ ...filters, consuming_user_id: event.target.value })}
            placeholder="user id"
          />
          <input value={filters.status ?? ""} onChange={(event) => setFilters({ ...filters, status: event.target.value })} placeholder="status" />
          <button onClick={() => applyFilters()}>Apply</button>
        </div>
        <div className="receiptList">
          {receipts.map((receipt) => (
            <button key={receipt.receipt_id} onClick={() => selectReceipt(receipt.receipt_id)}>
              <strong>{receipt.receipt_id}</strong>
              <span>
                {receipt.synthetic_model} {"->"} {receipt.selected_model}
              </span>
              <small>
                {receipt.caller.consuming_agent_id?.value ?? "unknown agent"} / {receipt.caller.consuming_user_id?.value ?? "unknown user"}
              </small>
              <Badge value={receipt.status} />
            </button>
          ))}
        </div>
      </div>
      <div className="panel">
        <h2>Caller provenance</h2>
        {selectedReceipt ? <ReceiptDetail receipt={selectedReceipt} /> : <Empty message="Select a receipt to inspect source attribution." />}
      </div>
    </section>
  );
}

function Providers({ providers, models, selectedModel }: { providers: Provider[]; models: SyntheticModel[]; selectedModel?: SyntheticModel }) {
  const usage = new Map<string, number>();
  models.forEach((model) => {
    model.route_graph.nodes.forEach((node) => {
      if (node.provider_id) usage.set(node.provider_id, (usage.get(node.provider_id) ?? 0) + 1);
    });
  });

  return (
    <section className="panel">
      <div className="panelHeader">
        <div>
          <h2>Providers</h2>
          <p>Internal route targets exposed through the admin contract, not public model IDs.</p>
        </div>
        {selectedModel && <Badge value={`selected route: ${selectedModel.id}`} />}
      </div>
      <div className="providerGrid">
        {providers.map((provider) => (
          <article className="provider" key={provider.id}>
            <div>
              <strong>{provider.id}</strong>
              <Badge value={provider.health ?? "unknown"} />
            </div>
            <span>{provider.kind}</span>
            <code>{provider.base_url}</code>
            <div className="kv tight">
              <span>Credential owner</span>
              <strong>{provider.credential_owner}</strong>
              <span>Routes</span>
              <strong>{usage.get(provider.id) ?? 0}</strong>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}

function Storage({
  storageProviders,
  storageHealth,
  sinks,
  receipts,
}: {
  storageProviders: StorageProvider[];
  storageHealth: StorageHealth | null;
  sinks: Sink[];
  receipts: ReceiptSummary[];
}) {
  const visibleStorageProviders = storageHealth ? [storageProviderFromHealth(storageHealth, receipts.length), ...storageProviders] : storageProviders;
  const primaryStore = visibleStorageProviders.find((provider) => provider.role === "system_of_record") ?? visibleStorageProviders[0];
  const projectedReceiptCount = sinks.reduce((total, sink) => total + (sink.indexed_receipts ?? 0), 0);
  const healthySinks = sinks.filter((sink) => sink.status === "healthy").length;

  return (
    <section className="storageLayout">
      <div className="panel">
        <div className="panelHeader">
          <div>
            <h2>Receipt storage</h2>
            <p>Durable providers keep queryable receipt history; sinks hold redacted projections.</p>
          </div>
          {primaryStore && <Badge value={`system of record: ${primaryStore.id}`} />}
        </div>
        <div className="metricGrid">
          <Metric label="Receipts" value={String(primaryStore?.receipt_count ?? receipts.length)} />
          <Metric label="Receipt events" value={String(primaryStore?.event_count ?? 0)} />
          <Metric label="Healthy sinks" value={`${healthySinks}/${sinks.length}`} />
          <Metric label="Indexed copies" value={String(projectedReceiptCount)} />
        </div>
        <div className="storageCards">
          {visibleStorageProviders.map((provider) => (
            <article className="storageCard" key={provider.id}>
              <div className="cardTitle">
                <strong>{provider.id}</strong>
                <Badge value={provider.status} />
              </div>
              <span>{provider.kind}</span>
              <div className="kv tight">
                <span>Role</span>
                <strong>{provider.role}</strong>
                <span>Contract</span>
                <strong>{provider.contract_version}</strong>
                <span>Migration</span>
                <strong>{provider.migration_version}</strong>
                <span>Failure policy</span>
                <strong>{provider.failure_policy}</strong>
                <span>Retention</span>
                <strong>{provider.retention_days ? `${provider.retention_days} days` : "export snapshot"}</strong>
              </div>
              <div className="chipRow">
                {provider.capabilities.map((capability) => (
                  <span className="chip" key={capability}>
                    {capability}
                  </span>
                ))}
              </div>
            </article>
          ))}
        </div>
      </div>

      <div className="panel">
        <div className="panelHeader compact">
          <div>
            <h2>Sinks</h2>
            <p>Derived outputs for search, event replay, and operator diagnostics.</p>
          </div>
        </div>
        <div className="sinkTimeline">
          {sinks.map((sink) => (
            <article className="sinkRow" key={sink.id}>
              <div className="cardTitle">
                <div>
                  <strong>{sink.id}</strong>
                  <span>{sink.kind}</span>
                </div>
                <Badge value={sink.status} />
              </div>
              <code>{sink.target}</code>
              <div className="kv tight">
                <span>Derived from</span>
                <strong>{sink.derived_from}</strong>
                <span>Delivery</span>
                <strong>{sink.delivery}</strong>
                <span>Lag</span>
                <strong>{sink.lag_ms ?? 0} ms</strong>
                <span>Backlog</span>
                <strong>{sink.backlog ?? 0}</strong>
                <span>Redaction</span>
                <strong>{sink.redaction}</strong>
                <span>Failure policy</span>
                <strong>{sink.failure_policy}</strong>
              </div>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

function storageProviderFromHealth(health: StorageHealth, receiptCount: number): StorageProvider {
  const capabilities = Object.entries(health.capabilities)
    .filter(([, enabled]) => enabled === true)
    .map(([name]) => name);
  return {
    id: `live-${health.kind}`,
    kind: health.kind === "json-file" ? "sqlite" : health.kind,
    role: "system_of_record",
    status: health.read_health === "ok" && health.write_health === "ok" ? "healthy" : "degraded",
    contract_version: health.contract_version,
    migration_version: String(health.migration_version),
    failure_policy: "fail_closed",
    receipt_count: receiptCount,
    event_count: 0,
    capabilities,
  };
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function ReceiptDetail({ receipt }: { receipt: Receipt }) {
  return (
    <div className="receiptDetail">
      <div className="kv">
        <span>Receipt</span>
        <strong>{receipt.receipt_id}</strong>
        <span>Model</span>
        <strong>{receipt.synthetic_model}</strong>
        <span>Version</span>
        <strong>{receipt.synthetic_version}</strong>
        <span>Status</span>
        <strong>{String(receipt.final.status ?? "unknown")}</strong>
      </div>
      {receipt.persistence && (
        <>
          <h3>Persistence</h3>
          <div className="kv">
            <span>Stored</span>
            <strong>{receipt.persistence.stored ? "yes" : "no"}</strong>
            <span>Storage provider</span>
            <strong>{receipt.persistence.storage_provider_id}</strong>
            <span>Events</span>
            <strong>{receipt.persistence.event_count}</strong>
            <span>Sink projection</span>
            <strong>{receipt.persistence.sink_projection_status}</strong>
            <span>Projected sinks</span>
            <strong>{receipt.persistence.projected_sink_ids.join(", ") || "none"}</strong>
          </div>
        </>
      )}
      <h3>Caller</h3>
      <CallerTable caller={receipt.caller} />
      <h3>Decision</h3>
      <pre>{JSON.stringify(receipt.decision, null, 2)}</pre>
      <h3>Attempts</h3>
      <pre>{JSON.stringify(receipt.attempts, null, 2)}</pre>
      <h3>Final</h3>
      <pre>{JSON.stringify(receipt.final, null, 2)}</pre>
    </div>
  );
}

function CallerTable({ caller }: { caller: CallerContext }) {
  const rows = Object.entries(caller).filter(([key]) => key !== "tags");
  return (
    <table className="miniTable">
      <tbody>
        {rows.map(([key, sourced]) => {
          if (!sourced || Array.isArray(sourced)) return null;
          return (
            <tr key={key}>
              <td>{key}</td>
              <td>{sourced.value}</td>
              <td>
                <Badge value={sourced.source} />
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

function Badge({ value }: { value: string }) {
  return <span className={`badge ${value.replace(/[^a-z0-9]/gi, "-").toLowerCase()}`}>{value}</span>;
}

function Empty({ message }: { message: string }) {
  return <div className="empty">{message}</div>;
}

function formatPercent(value?: number) {
  if (value === undefined) return "0%";
  return `${(value * 100).toFixed(1)}%`;
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
