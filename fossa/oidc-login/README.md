# FOSSA OIDC Login

Exchanges the job's GitHub OIDC token for a short-lived FOSSA API token of a FOSSA service account. No FOSSA token has to be stored in Vault or GitHub.

## 🚀 Usage

```yaml
jobs:
  check-licenses:
    # Forked pull requests get no OIDC token
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    permissions:
      contents: read
      id-token: write  # GitHub OIDC token for the FOSSA token exchange
    steps:
    - name: Log in to FOSSA
      id: fossa-login
      uses: camunda/infra-global-github-actions/fossa/oidc-login@<sha> # <version>
      with:
        provider-id: '81'
        username: ci-camunda-infra
        push-only: 'false'  # pr-check, wait-for-scan and get-issues call the FOSSA API
    - uses: camunda/infra-global-github-actions/fossa/analyze@<sha> # <version>
      with:
        api-key: ${{ steps.fossa-login.outputs.api-key }}
        # ...
```

## ⚙️ Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `provider-id` | Numeric ID of the FOSSA OIDC provider | Yes | - |
| `username` | Username of the FOSSA service account | Yes | - |
| `audience` | Audience of the GitHub OIDC token, must be accepted by the trust relationship | No | `app.fossa.com` |
| `expires-in` | Token lifetime in seconds (900 to 43200) | No | `3600` |
| `push-only` | Request a push-only token, enough for `fossa/analyze` only | No | `'true'` |

## 📤 Outputs

| Output | Description |
|--------|-------------|
| `api-key` | The FOSSA API token (masked) |

## 📋 Existing setup

| OIDC provider ID | Scope | Service account | Trusted `sub` claims |
| --- | --- | --- | --- |
| 81 | Team: Infra Team | `ci-camunda-infra` | `repo:camunda/infra-global-github-actions:*` |

## 🔧 Onboard a repository

Needs the FOSSA org **Admin** role (Infra Team members have it). Ask in #ask-infra otherwise.

### 1. Create the service account

Skip this if the owning team already has a service account in the table above.

Open <https://app.fossa.com/account/settings/integrations/api_user> (Integrations → API Service Accounts) and fill in:

| Field | Value |
| --- | --- |
| Username | `ci-camunda-<team>` |
| Name / Email | empty |
| Organization Role | Manage Organizational Portal Reports (only needed to publish release reports to the portal, otherwise `None`) |
| Team / Team Role | the owning team / Team Admin (needed to create projects on first scan) |
| Push-only / full API token | both unchecked |

Assigning the team here works without touching the SAML settings.

### 2. Add the OIDC provider

Skip this if the team already has a provider in the table above.

Open <https://app.fossa.com/account/settings/integrations/oidc> (Integrations → OIDC Providers), click **Add an OIDC provider** and fill in:

| Field | Value |
| --- | --- |
| Issuer URL | `https://token.actions.githubusercontent.com` |
| Scope | Team → the owning team |

Note the numeric provider ID shown in the list after saving.

### 3. Add a trust relationship

On the same page, open the provider (eye icon in the Actions column) and click **Add a trust relationship**:

| Field | Value |
| --- | --- |
| Scope | Team → the owning team |
| Service Account | the account from step 1 |
| Audiences | `app.fossa.com` |
| Required Claims | `sub` = `repo:camunda/<repo>:*`, wildcards enabled |

Add the repository to the [existing setup](#-existing-setup) table.

## ⚠️ Traps

- **Service accounts can be missing from the user list.** Organization → Users does not show every service account (e.g. `ci-infra`), and FOSSA rejects such a name as taken. Check Integrations → API Service Accounts before picking a username.
- **Buttons render disabled until permissions load.** "Add an OIDC provider" shows a missing-permission overlay for a few seconds after page load. Wait, then click.
- **Trust relationships cannot be broader than their provider.** A team-scoped provider only binds service accounts of that team, so each team needs its own provider.
- **FOSSA stores the issuer with a trailing slash** (`https://token.actions.githubusercontent.com/`). If the token exchange fails with "JWT does not match any trust relationship", recreate the provider without it.

## 📚 References

- [FOSSA: OpenID Connect](https://docs.fossa.com/docs/openid-connect)
