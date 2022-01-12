# assert-camunda-git-emails

This composite Github Action (GHA) is supposed to be used by other teams inside Camunda in their private repositories to make sure that Git commits are done with company email addresses (`@camunda.com`) instead of private email addresses.

## Usage

This composite GHA should be run on Pull Requests to prevent Git commits with violating email addresses reaching the default branch of your repository.

Place the below Github Action workflow in your private repository as `.github/workflows/assert-camunda-git-emails.yml`:

```yaml
---
name: assert-camunda-git-emails

on: [pull_request]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/assert-camunda-git-emails@main
```

### Allowed Email Addresses

The following email addresses are hardcoded as allowed:

- `@camunda.com` (used by employees)
- `@users.noreply.github.com` (used for Github users that chose to [keep their email address private](https://docs.github.com/en/account-and-profile/setting-up-and-managing-your-github-user-account/managing-email-preferences/adding-an-email-address-to-your-github-account))
- `noreply@github.com` (used on merge commits created by Github web UI)

**Note: Pull Requests to extend this list are welcome when you discover edge cases!**

You can also specify additional allowed email addresses via an input as a `grep` regex:

```yaml
---
name: assert-camunda-git-emails

on: [pull_request]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/assert-camunda-git-emails@main
      with:
        additional-allowed-emails-regex: "test@example.com\\|foo@example.org"
```
