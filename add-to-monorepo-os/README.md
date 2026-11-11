# add-to-monorepo-os

Adds the issues and pull requests of [Monorepo OS](https://github.com/camunda/monorepo-os) pilot users to the Monorepo OS board and sets their Due Date, so the Monorepo OS webapp can show them as one queue. Only the pilot users listed in `ROSTER` in [`index.js`](index.js) count; anything else is skipped.

## Rules

Due Dates count business days (Monday to Friday) from today. "If empty" keeps a date humans set; "reset" replaces it. A date humans cleared comes back on the next event that sets one, such as a reassignment, but not from a backfill.

| Event | Added when | Due Date |
| --- | --- | --- |
| `issues: assigned` | a pilot user is assigned to an open issue | +10, if empty |
| `pull_request: review_requested` | a pilot user is requested to review, re-requests included; team requests are skipped | +2, reset |
| `pull_request: opened`, `reopened`, `ready_for_review` | a pilot user authored it or is already requested to review; a pilot author is assigned if it has no assignee yet | +2, if empty |
| `pull_request_review: submitted` | an approval of a pull request a pilot user authored or is assigned to | +2, reset |
| `workflow_dispatch` | backfill: every open issue assigned to a pilot user, and every open pull request a pilot user authored or is requested to review, in the calling repository that is not on the board yet; pilot authors are assigned as above | +10 for issues, +2 for pull requests |

Assigning the author makes them the owner of the merge, as an assignee owns an issue, both for the webapp and for anything else that reads assignees. Draft and closed pull requests are skipped. The action never removes items from the board: an issue whose assignee drops it keeps its date, and the webapp lists it under Needs attention.

The backfill fills the board for a repository that starts calling the action, and rebuilds a wiped board. It leaves items already on the board alone, so it never brings back a Due Date someone cleared.

## Inputs

| Input | Description |
| --- | --- |
| `github-token` | Token of the Monorepo OS GitHub App, which assigns pull request authors and writes the board (required) |
| `project-url` | The board, `https://github.com/orgs/camunda/projects/267` by default; point it at a copy of the board to test |
| `dry-run` | If `true`, logs what would be added and dated without writing to the board (default `false`) |

## Usage

```yaml
---
name: Add to Monorepo OS

on:
  issues:
    types: [assigned]
  pull_request:
    types: [opened, reopened, ready_for_review, review_requested]
  pull_request_review:
    types: [submitted]
  workflow_dispatch:

permissions: {}

jobs:
  add-to-monorepo-os:
    # Pull requests from forks get no secrets, so no token can be minted for them.
    if: github.event.pull_request.head.repo.fork != true
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      id-token: write  # mint GitHub OIDC token for Vault JWT auth
    steps:
    - name: Generate GitHub token
      id: github-token
      uses: camunda/infra-global-github-actions/generate-github-app-token-from-vault-secrets@<sha>  # generate-github-app-token-from-vault-secrets-X.Y.Z
      with:
        github-app-id-vault-key: <key of the Monorepo OS App ID>
        github-app-id-vault-path: <Vault path of the Monorepo OS App>
        github-app-private-key-vault-key: <key of the Monorepo OS App private key>
        github-app-private-key-vault-path: <Vault path of the Monorepo OS App>
        vault-auth-method: jwt
        vault-auth-jwt-path: ${{ secrets.VAULT_JWT_PATH }}
        vault-auth-jwt-role: ${{ secrets.VAULT_JWT_ROLE }}
        vault-auth-jwt-audience: ${{ secrets.VAULT_JWT_AUDIENCE }}
        vault-url: ${{ secrets.VAULT_ADDR }}
    - uses: camunda/infra-global-github-actions/add-to-monorepo-os@<sha>  # add-to-monorepo-os-X.Y.Z
      with:
        github-token: ${{ steps.github-token.outputs.token }}
```

The Monorepo OS App must be installed on the calling repository.

## Development

```shell
cd add-to-monorepo-os && node --test
```
