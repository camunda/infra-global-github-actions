# Global Github Actions

This repository contains Github Actions (GHA) maintained by the Infra team. Those actions are intended to be consumed by other teams inside Camunda.

They are **publicly accessible** and thus must not contain any secrets.

## Contributing

Before contributing, please make sure to activate `pre-commit` in this repository:

```shell
pre-commit install --install-hooks -t commit-msg -t pre-commit
```
