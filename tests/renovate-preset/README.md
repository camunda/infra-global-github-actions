# Renovate preset fixtures

Fixtures for [`test-renovate-preset.yml`](../../.github/workflows/test-renovate-preset.yml). Each file pins the same release; the test asserts the preset tracks it in every YAML file and not in this one:

```yaml
- uses: camunda/infra-global-github-actions/teams/infra/pull-request/automerge@d56c158341637cc71ed42e34040e9db0d0026b6c # pull-request-1.1.0
```
