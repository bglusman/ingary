# Branch Protection

The `main` branch should require PRs once bootstrap infrastructure is merged.

Recommended required checks:

- `test`
- `gitleaks`
- `zizmor`

Do not make Pages a required check until the Pages workflow runs on every PR.
The initial workflow only deploys docs changes from `main`, so requiring it on
ordinary PRs would leave merges blocked by a check that never starts.

Recommended settings:

- Require a pull request before merging.
- Require at least one approval.
- Dismiss stale approvals when new commits are pushed.
- Require status checks to pass before merging.
- Require branches to be up to date before merging.
- Restrict force pushes.
- Restrict branch deletion.

The initial bootstrap may need one direct push before these checks exist on the
repository.
