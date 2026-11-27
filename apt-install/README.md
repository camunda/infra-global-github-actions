# 📦 apt-install

Installs apt packages on a runner whose Ubuntu mirror may be slow or unreachable.

## 🔧 Usage

```yaml
- name: Install gettext
  uses: camunda/infra-global-github-actions/apt-install@<sha> # <family>-X.Y.Z
  with:
    packages: gettext-base
```

| Input | Default | Description |
|:------|:--------|:------------|
| `packages` | required | Space-separated list of apt packages. |
| `timeout` | `115` | Per-attempt timeout in seconds for update and install. |
| `max-attempts` | `3` | Attempts before the step fails. |
| `no-install-recommends` | `true` | Pass `--no-install-recommends`. |
| `skip-if-exists` | empty | Absolute path that skips the install when it exists, so a mirror outage cannot fail a runner that already has the tool. |

## 🤔 Why

- `apt-get update` exits 100 when any single configured repository fails, even one unrelated to the packages. The action ignores that exit code, so `apt-get install` is the only gate.
- A hung mirror is killed by `timeout` and retried instead of waiting out apt's default per-mirror timeout.
- `Acquire::http::Timeout`, `Acquire::https::Timeout` and `Acquire::Retries` are written to `/etc/apt/apt.conf.d/99-fast-mirror-failover.conf`, so apt gives up on an unresponsive mirror after seconds and, when the runner lists more than one, continues with the next.

## ⚠️ Constraints

- Needs passwordless `sudo` on a Debian or Ubuntu runner.
- The action configures no alternate mirror. A package that is not already installed or cached cannot be installed while every mirror configured on the runner is unreachable. Use `skip-if-exists` for tools the runner image already ships.
- Third-party repositories (for example PGDG) are not configured here. Add the repository in a step of your own and install the package with this action afterwards.
