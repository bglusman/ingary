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
import "./styles.css";
import type {
  CallerContext,
  Provider,
  Receipt,
  ReceiptFilters,
  ReceiptSummary,
  SimulationResult,
  StorageHealth,
  StorageProvider,
  SyntheticModel,
  SyntheticModelSummary,
} from "./types";

const navItems = ["Catalog", "Routes", "Governance", "Simulator", "Receipts", "Providers", "Storage"] as const;
type View = (typeof navItems)[number];

type GovernanceRuleCard = {
  id: string;
  phase: string;
  match: string;
  action: string;
  arbitration: "parallel-safe" | "ordered" | "hard-conflict";
  priority: number;
  effects: string[];
  summary: string;
};

type GovernancePhase = {
  id: string;
  title: string;
  description: string;
  rules: GovernanceRuleCard[];
};

type TimelineChunk = {
  id: string;
  label: string;
  text: string;
  status: "released" | "held" | "matched" | "aborted" | "retry";
};

const assistantModels = ["Local backend model", "Ollama review model", "Managed reviewer with explicit permission"];

const governancePhases: GovernancePhase[] = [
  {
    id: "request",
    title: "Request",
    description: "Normalize intent, caller scope, and cache visibility before routing.",
    rules: [
      {
        id: "cache-context-window",
        phase: "request",
        match: "caller.session_id has recent retry failures >= 2",
        action: "annotate request risk",
        arbitration: "parallel-safe",
        priority: 20,
        effects: ["reads policy_cache.session", "writes request.annotations"],
        summary: "Reads bounded recent cache data and adds a risk annotation without changing the prompt.",
      },
    ],
  },
  {
    id: "route",
    title: "Route",
    description: "Choose providers after request annotations and hard route gates are known.",
    rules: [
      {
        id: "cloud-escalation-gate",
        phase: "route",
        match: "request.annotations contains private-data-risk",
        action: "require local route",
        arbitration: "ordered",
        priority: 40,
        effects: ["reads request.annotations", "writes route.allowed_targets"],
        summary: "Forces local-only routing when upstream request analysis marks a private-data risk.",
      },
    ],
  },
  {
    id: "stream",
    title: "Stream",
    description: "Watch provider deltas with bounded horizons before content is released.",
    rules: [
      {
        id: "no-old-client",
        phase: "response.streaming",
        match: 'regex "OldClient\\(" within 4096 bytes',
        action: "abort, inject reminder, retry once",
        arbitration: "ordered",
        priority: 50,
        effects: ["reads stream.window", "writes attempt.retry", "writes request.system_reminder"],
        summary: "TTSR rule holds a bounded stream window, aborts before the bad span is released, then retries with a reminder.",
      },
      {
        id: "secret-shape-block",
        phase: "response.streaming",
        match: "known token-shaped text in stream window",
        action: "block final",
        arbitration: "hard-conflict",
        priority: 90,
        effects: ["reads stream.window", "writes final.status"],
        summary: "Blocks final output if a high-confidence secret-shaped span appears in the unreleased stream.",
      },
    ],
  },
  {
    id: "final",
    title: "Final",
    description: "Validate the final response, persist receipts, and emit operator signals.",
    rules: [
      {
        id: "receipt-policy-trace",
        phase: "final",
        match: "any policy action occurred",
        action: "persist receipt events",
        arbitration: "parallel-safe",
        priority: 10,
        effects: ["reads policy.events", "writes receipt.events"],
        summary: "Adds deterministic policy events to the receipt without changing the model answer.",
      },
    ],
  },
];

const timelineChunks: TimelineChunk[] = [
  { id: "chunk-1", label: "chunk 1", text: "Use the new adapter and", status: "released" },
  { id: "chunk-2", label: "chunk 2", text: " avoid introducing ", status: "held" },
  { id: "chunk-3", label: "chunk 3", text: "OldClient(", status: "matched" },
  { id: "chunk-4", label: "abort", text: "provider stream closed before release", status: "aborted" },
  { id: "chunk-5", label: "retry", text: "system reminder injected for second attempt", status: "retry" },
];

const generatedChecks = [
  "Trigger split across stream chunks",
  "Trigger at 4096-byte horizon boundary",
  "Near-miss text remains releasable",
  "Retry violation blocks final output",
  "Receipt includes abort and retry events",
];

const receiptPreview = {
  receipt_id: "simulated-policy-receipt",
  synthetic_model: "coding-balanced",
  policy_version: "draft.ttsr.001",
  stream: {
    rule_matched: "no-old-client",
    released_to_consumer: false,
    abort_offset: 42,
    retry_attempted: true,
  },
  events: [
    { type: "stream.window_held", rule_id: "no-old-client", horizon_bytes: 4096 },
    { type: "stream.rule_matched", rule_id: "no-old-client", match_kind: "regex" },
    { type: "attempt.aborted", reason: "tts_rule_matched" },
    { type: "attempt.retry_requested", reminder_id: "no-old-client.reminder" },
  ],
};

const governanceDslPreview = `kind: ingary.governance.policy
version: v1
id: coding-balanced-governance-draft
rules:
  - id: no-old-client
    phase: response.streaming
    match:
      regex: "OldClient\\\\("
    mode:
      type: buffered_horizon
      bytes: 4096
    action:
      type: retry_with_reminder
      max_retries: 1
      on_retry_violation: block_final
    priority: 50`;

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
        {view === "Governance" && <GovernanceWorkbench />}
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
        {view === "Storage" && <Storage storageHealth={storageHealth} receipts={receipts} />}
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
        <h2>Governance</h2>
        <div className="kv">
          <span>Mode</span>
          <strong>{model.stream_policy?.mode ?? "pass_through"}</strong>
          <span>Buffer</span>
          <strong>{model.stream_policy?.buffer_tokens ?? 0} tokens</strong>
          <span>Rules</span>
          <strong>{model.stream_policy?.rules?.length ?? 0}</strong>
          <span>Prompt transform</span>
          <strong>{model.prompt_transforms?.preamble || model.prompt_transforms?.postscript ? "configured" : "none"}</strong>
          <span>Structured output</span>
          <strong>{model.structured_output?.mode ?? "none"}</strong>
          <span>Policy descriptors</span>
          <strong>{model.governance?.length ?? 0}</strong>
        </div>
        <pre>{JSON.stringify({ stream_policy: model.stream_policy, prompt_transforms: model.prompt_transforms, structured_output: model.structured_output, governance: model.governance }, null, 2)}</pre>
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
            <p>Posts to the selected backend's /v1/synthetic/simulate endpoint.</p>
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

function GovernanceWorkbench() {
  const [intent, setIntent] = useState(
    "When streamed code mentions OldClient(, stop it before users see it, retry once with a precise reminder, then block if the retry still violates.",
  );
  const [assistantModel, setAssistantModel] = useState(assistantModels[0]);
  const [assistantAllowed, setAssistantAllowed] = useState(false);
  const [selectedRuleId, setSelectedRuleId] = useState("no-old-client");
  const selectedRule =
    governancePhases.flatMap((phase) => phase.rules).find((rule) => rule.id === selectedRuleId) ?? governancePhases[2].rules[0];

  return (
    <section className="governanceLayout">
      <div className="panel governanceIntent">
        <div className="panelHeader compact">
          <div>
            <h2>Policy authoring</h2>
            <p>Draft rules from plain-language intent, then review the deterministic artifact before activation.</p>
          </div>
          <Badge value="local mock" />
        </div>
        <label>
          Intent
          <textarea value={intent} onChange={(event) => setIntent(event.target.value)} rows={5} />
        </label>
        <div className="assistantBox">
          <div className="assistantControls">
            <label>
              Assistant model
              <select value={assistantModel} onChange={(event) => setAssistantModel(event.target.value)}>
                {assistantModels.map((model) => (
                  <option value={model} key={model}>
                    {model}
                  </option>
                ))}
              </select>
            </label>
            <label className="check">
              <input type="checkbox" checked={assistantAllowed} onChange={(event) => setAssistantAllowed(event.target.checked)} />
              Allow this draft to be sent to the selected model
            </label>
          </div>
          <div className="assistantDraft">
            <Badge value={assistantAllowed ? "permission granted" : "permission required"} />
            <strong>Assistant draft review</strong>
            <p>
              Proposed TTSR rule: watch an unreleased 4096-byte stream horizon for <code>OldClient(</code>, abort before release, retry once with a
              system reminder, then block final output on repeat violation.
            </p>
          </div>
        </div>
      </div>

      <div className="panel">
        <div className="panelHeader compact">
          <div>
            <h2>Governance pipeline</h2>
            <p>Detector rules can run together; mutating actions are resolved by the arbiter.</p>
          </div>
          <Badge value="draft policy" />
        </div>
        <div className="phaseGraph">
          {governancePhases.map((phase) => (
            <article className="phaseColumn" key={phase.id}>
              <div className="phaseHeader">
                <strong>{phase.title}</strong>
                <span>{phase.description}</span>
              </div>
              <div className="ruleStack">
                {phase.rules.map((rule) => (
                  <button className={selectedRule.id === rule.id ? "ruleCard selected" : "ruleCard"} key={rule.id} onClick={() => setSelectedRuleId(rule.id)}>
                    <div>
                      <strong>{rule.id}</strong>
                      <Badge value={rule.arbitration} />
                    </div>
                    <span>{rule.action}</span>
                    <small>priority {rule.priority}</small>
                  </button>
                ))}
              </div>
            </article>
          ))}
        </div>
      </div>

      <section className="split governanceSplit">
        <div className="panel">
          <div className="panelHeader compact">
            <div>
              <h2>Selected rule</h2>
              <p>{selectedRule.summary}</p>
            </div>
            <Badge value={selectedRule.phase} />
          </div>
          <div className="kv">
            <span>Match</span>
            <strong>{selectedRule.match}</strong>
            <span>Action</span>
            <strong>{selectedRule.action}</strong>
            <span>Arbitration</span>
            <strong>{selectedRule.arbitration}</strong>
            <span>Priority</span>
            <strong>{selectedRule.priority}</strong>
          </div>
          <h3>Effects</h3>
          <div className="chipRow">
            {selectedRule.effects.map((effect) => (
              <span className="chip" key={effect}>
                {effect}
              </span>
            ))}
          </div>
        </div>

        <div className="panel">
          <div className="panelHeader compact">
            <div>
              <h2>Conflict review</h2>
              <p>Static labels show which rules need ordering before they can mutate runtime state.</p>
            </div>
          </div>
          <div className="conflictList">
            <div>
              <Badge value="parallel-safe" />
              <span>Cache annotation and receipt trace rules only write independent metadata.</span>
            </div>
            <div>
              <Badge value="ordered" />
              <span>TTSR retry and route gates mutate request or route state and use explicit priority.</span>
            </div>
            <div>
              <Badge value="hard-conflict" />
              <span>Secret blocking overrides retry actions when both match the same unreleased stream window.</span>
            </div>
          </div>
        </div>
      </section>

      <section className="split governanceSplit">
        <div className="panel">
          <div className="panelHeader compact">
            <div>
              <h2>Stream simulation</h2>
              <p>Mock timeline for held, released, matched, aborted, and retried stream chunks.</p>
            </div>
            <Badge value="TTSR" />
          </div>
          <div className="timeline">
            {timelineChunks.map((chunk) => (
              <div className={`timelineChunk ${chunk.status}`} key={chunk.id}>
                <span>{chunk.label}</span>
                <strong>{chunk.text}</strong>
                <Badge value={chunk.status} />
              </div>
            ))}
          </div>
          <h3>Generated checks</h3>
          <div className="checkGrid">
            {generatedChecks.map((check) => (
              <div key={check}>
                <Badge value="planned" />
                <span>{check}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="panel">
          <div className="panelHeader compact">
            <div>
              <h2>Counterexample panel</h2>
              <p>Static placeholder for property failures and pinned regression fixtures.</p>
            </div>
            <Badge value="not wired" />
          </div>
          <div className="counterexample">
            <strong>Boundary case to test next</strong>
            <span>
              Regex match begins 3 bytes before the release horizon and completes in the next chunk. Expected: keep the prefix held until the detector can
              decide whether to abort.
            </span>
          </div>
          <h3>Receipt preview</h3>
          <pre>{JSON.stringify(receiptPreview, null, 2)}</pre>
        </div>
      </section>

      <div className="panel">
        <div className="panelHeader compact">
          <div>
            <h2>Review artifact</h2>
            <p>Advanced editor surface for the compiled deterministic DSL, not the primary user workflow.</p>
          </div>
          <Badge value="YAML draft" />
        </div>
        <pre>{governanceDslPreview}</pre>
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
                {receipt.caller?.consuming_agent_id?.value ?? "unknown agent"} / {receipt.caller?.consuming_user_id?.value ?? "unknown user"}
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

function Storage({ storageHealth, receipts }: { storageHealth: StorageHealth | null; receipts: ReceiptSummary[] }) {
  const primaryStore = storageHealth ? storageProviderFromHealth(storageHealth, receipts.length) : null;

  return (
    <section className="storageLayout">
      <div className="panel">
        <div className="panelHeader">
          <div>
            <h2>Receipt storage</h2>
            <p>Live storage health reported by the selected backend.</p>
          </div>
          {primaryStore && <Badge value={`system of record: ${primaryStore.id}`} />}
        </div>
        {primaryStore ? (
          <>
            <div className="metricGrid">
              <Metric label="Receipts" value={String(primaryStore.receipt_count)} />
              <Metric label="Receipt events" value={String(primaryStore.event_count)} />
              <Metric label="Read health" value={storageHealth?.read_health ?? "unknown"} />
              <Metric label="Write health" value={storageHealth?.write_health ?? "unknown"} />
            </div>
            <div className="storageCards">
              <article className="storageCard" key={primaryStore.id}>
                <div className="cardTitle">
                  <strong>{primaryStore.id}</strong>
                  <Badge value={primaryStore.status} />
                </div>
                <span>{primaryStore.kind}</span>
                <div className="kv tight">
                  <span>Role</span>
                  <strong>{primaryStore.role}</strong>
                  <span>Contract</span>
                  <strong>{primaryStore.contract_version}</strong>
                  <span>Migration</span>
                  <strong>{primaryStore.migration_version}</strong>
                  <span>Failure policy</span>
                  <strong>{primaryStore.failure_policy}</strong>
                  <span>Retention</span>
                  <strong>not implemented</strong>
                </div>
                <div className="chipRow">
                  {primaryStore.capabilities.map((capability) => (
                    <span className="chip" key={capability}>
                      {capability}
                    </span>
                  ))}
                </div>
              </article>
            </div>
          </>
        ) : (
          <Empty message="Storage health is unavailable because the selected backend did not answer /admin/storage." />
        )}
      </div>

      <div className="panel">
        <div className="panelHeader compact">
          <div>
            <h2>Sinks</h2>
            <p>Not implemented in the live backend contract yet.</p>
          </div>
          <Badge value="not implemented" />
        </div>
        <Empty message="Search, event stream, operator log, and metrics sinks were removed from the live UI until /admin/sinks exposes real backend state." />
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
