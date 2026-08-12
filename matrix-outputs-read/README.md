# matrix-outputs-read

This composite GitHub Action collects the per-job outputs written by a matrix step and merges them into a single JSON object, keyed by output name then by matrix key.

It is a drop-in replacement for [`cloudposse/github-action-matrix-outputs-read`](https://github.com/cloudposse/github-action-matrix-outputs-read). Pair it with [`cloudposse/github-action-matrix-outputs-write`](https://github.com/cloudposse/github-action-matrix-outputs-write), which is unaffected and needs no replacement.

## Why this exists

The upstream action's own `action.yml` references two actions without pinning them:

```yaml
- uses: dcarbone/install-jq-action@v2.1.0
- uses: actions/download-artifact@v4
```

GitHub evaluates the **Require actions to be pinned to a full-length commit SHA** repository setting over the *entire* dependency tree at `Set up job`. A caller with that setting enabled therefore has its job refused before any step runs, and cannot work around it by choosing a different revision of the upstream action:

```
The actions dcarbone/install-jq-action@v2.1.0 and actions/download-artifact@v4
are not allowed in <repo> because all actions must be pinned to a full-length commit SHA.
```

Upstream's last release is `1.0.0` (2024-02-28) and its `main` branch is still unpinned, so there is no revision to move to.

## Usage

### Inputs

| Input name | Description | Required | Default |
| :--------: | :---------- | :------: | :-----: |
| matrix-step-name | Name passed as `matrix-step-name` to the matching write step. It is also the artifact file name this action looks for. | :heavy_check_mark: | |

### Outputs

| Output name | Description |
| :---------: | :---------- |
| result | Merged JSON object. For a matrix writing `{"kube": "..."}` under keys `c1` and `c2`, the result is `{"kube": {"c1": "...", "c2": "..."}}`. |

### Example

```yaml
jobs:
  prepare-clusters:
    strategy:
      matrix:
        cluster: [c1, c2]
    steps:
      - uses: cloudposse/github-action-matrix-outputs-write@ed06cf3a6bf23b8dce36d1cf0d63123885bb8375 # v1
        with:
          matrix-step-name: prepare-clusters
          matrix-key: ${{ matrix.cluster }}
          outputs: |
            kube: ${{ steps.create.outputs.kubeconfig }}

  access-info:
    needs: prepare-clusters
    runs-on: ubuntu-latest
    outputs:
      config: ${{ steps.read.outputs.result }}
    steps:
      - uses: camunda/infra-global-github-actions/matrix-outputs-read@main
        id: read
        with:
          matrix-step-name: prepare-clusters
```

## Notes

### No `actions/checkout` in the calling job

This action downloads **every** artifact into the working directory and then walks it with `find . -maxdepth 2`. A checkout in the same job would place repository files inside that search path. Being a remote action, it needs no checkout of its own.

### jq is taken from the runner

The upstream action force-installs jq 1.6 through `dcarbone/install-jq-action`. That step is deliberately not reproduced: the GitHub-hosted runner images already ship jq, and both versions produce byte-identical output for this program, key ordering included.

```
jq 1.6    -> {"kube":{"c1":"x","c3":"z","c2":"y"},"extra":{"c1":1,"c2":2}}
jq 1.7.1  -> {"kube":{"c1":"x","c3":"z","c2":"y"},"extra":{"c1":1,"c2":2}}
```

A guard reports a clear error if `jq` is missing, which can happen on a self-hosted runner.

### Input handling

`matrix-step-name` is passed through the environment rather than interpolated into the script, so a value containing shell metacharacters cannot reach the command line.
