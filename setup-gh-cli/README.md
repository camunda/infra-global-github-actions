# setup-gh-cli

This composite GitHub Action installs the GitHub CLI (`gh`) if it's not already available on the runner.

## Usage

```yaml
- name: Setup GitHub CLI
  uses: camunda/infra-global-github-actions/setup-gh-cli@main
```

## Behavior

- Checks if GitHub CLI is already installed
- If not installed, installs it using the official GitHub CLI installation method
- Works on both GitHub-hosted and self-hosted runners
- Supports Ubuntu/Debian-based systems

The action will output the version of GitHub CLI after installation or if it was already present.
