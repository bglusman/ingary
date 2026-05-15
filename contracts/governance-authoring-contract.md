# Governance Authoring Contract

Wardwright governance should be authored through a visual and AI-assisted workflow,
then stored as deterministic policy artifacts. The assistant helps draft and
review policy, but compiled artifacts and simulator results define runtime
behavior.

## Authoring Flow

1. User describes desired behavior in plain language.
2. User selects or permits a backing model for authoring assistance.
3. Assistant drafts a governance artifact and plain-language summary.
4. Compiler validates schema, phases, effect sets, and action legality.
5. Conflict analyzer classifies rules as parallel-safe, ordered, ambiguous, or
   conflicting.
6. Simulator generates examples and counterexamples.
7. User reviews graph, summary, generated checks, and artifact diff.
8. Activation creates an immutable policy version.

## Artifact Role

YAML or TOML artifacts are the storage and advanced-review format. They are not
the primary user interface.

Artifacts must be:

- deterministic after normalization
- diffable and reviewable
- safe to simulate without provider access
- explicit about phases, matchers, actions, scopes, and effect sets
- compilable into a runtime plan with no hidden AI calls

## Assistant Boundaries

The assistant may:

- draft rules from intent
- explain rules and tradeoffs
- propose test cases and counterexamples
- review policy diffs
- suggest revisions after simulator failures

The assistant must not:

- activate policies without user approval
- run as the runtime policy evaluator
- hide generated DSL from review
- send provider credentials or hidden local config to a model
- treat private receipts or prompts as shareable unless the user explicitly
  includes them in the authoring context

Assistant provenance should be stored with drafts:

- model ID
- provider or local runtime kind
- prompt template version
- creation timestamp
- whether external model access was used
- user approval state

## Composition Model

Policy rules produce proposed actions. A deterministic arbiter resolves those
actions per phase.

Rule metadata must include:

- `phase`
- matcher definition
- action definition
- scope and once-per behavior where applicable
- declared reads and writes
- priority or arbitration strategy when effects can conflict

Conflict classes:

- `parallel_safe`: rules can evaluate together and cannot conflict.
- `ordered`: priority or declared strategy resolves competing actions.
- `ambiguous`: user confirmation is needed.
- `conflicting`: activation is rejected until the artifact changes.

## Simulation Requirements

The simulator must explain behavior through examples, not only pass/fail
booleans.

For stream rules, generated simulations should cover:

- trigger split across chunks
- trigger at holdback boundary
- near misses
- overlapping rule matches
- retry violation
- invalid or unsafe regex
- pass-through configurations that cannot guarantee non-release

Simulation output should include:

- matched rule IDs
- action chosen by the arbiter
- release/hold/abort timeline
- retry count and injected reminder
- whether violating bytes reached the consumer
- receipt event preview
- minimal counterexample when a property fails
