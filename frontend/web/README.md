# Ingary Web Prototype

Lightweight Vite + React + TypeScript console for the draft API in
`../../contracts/openapi.yaml`.

## Run

```bash
npm install
npm run dev
```

Vite serves the app at `http://127.0.0.1:5173`. The API client targets
`http://127.0.0.1:8787` for every contract endpoint. When that server is not
available, the app falls back to local mock data so the UI remains usable.

## Screens

- Model catalog with agent/user-oriented filters and 24h operational columns.
- Route graph view for full synthetic model records from `/admin/synthetic-models`.
- Simulator form that posts the contract shape to `/v1/synthetic/simulate`.
- Receipt explorer with filters and caller provenance source badges.
- Provider list from `/admin/providers`, showing which providers are route
  targets rather than public model IDs.

## UI / API Contract Critique

- The catalog endpoint exposes useful operational summary fields, but it has no
  first-class filter parameters. The prototype filters locally; real usage will
  probably need server-side `agent`, `user`, `status`, and `namespace` filters.
- Receipt caller provenance is strong for auditability. The UI benefits from
  `SourcedString`, but the contract may need stable display labels for source
  values before this is user-facing.
- Route nodes are intentionally extensible with `additionalProperties`; that is
  good for early backend experiments, but a graph editor will need typed config
  payloads per node kind.
- Simulation currently returns a full receipt, which is a good fit for the UI.
  A future contract could include explicit `dry_run: true` or `simulated: true`
  fields to distinguish planned attempts from persisted execution receipts.
