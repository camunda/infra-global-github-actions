# assert-no-ai-commits

This composite GitHub Action (GHA) is designed to prevent AI-authored commits from being merged into the main branch, in accordance with [Camunda's AI Policy](https://confluence.camunda.com/spaces/HAN/pages/245401394/Usage+of+Copilot+AI+tools+within+Engineering). The policy states that commits created by AI should be attributed to people first.

## Purpose

This action helps enforce the policy by:
- Detecting commits that are directly authored by AI tools (GitHub Copilot, ChatGPT, etc.)
- Preventing PRs containing AI-authored commits from being merged
- Ensuring proper human attribution of AI-assisted code

## Usage

This composite GHA should be run on Pull Requests to prevent AI-authored commits from reaching the default branch of your repository.

Place the following GitHub Action workflow in your repository as `.github/workflows/assert-no-ai-commits.yml`:

```yaml
---
name: assert-no-ai-commits

on: [pull_request]

jobs:
  check-ai-commits:
    runs-on: ubuntu-latest
    steps:
    - uses: camunda/infra-global-github-actions/assert-no-ai-commits@main
```

## What it Detects

The action checks for various AI-related patterns in commits:

### Co-authored-by Trailers
- `Co-authored-by: GitHub Copilot <...>`
- `Co-authored-by: Copilot <...>`
- `Co-authored-by: ChatGPT <...>`
- `Co-authored-by: OpenAI <...>`
- `Co-authored-by: Claude <...>`
- And other AI assistant patterns

### Author/Committer Names
- Names containing: "Copilot", "GPT", "ChatGPT", "OpenAI", "Claude", "AI Assistant", etc.

### Author/Committer Emails
- Emails containing: "copilot@", "gpt@", "ai@", "chatgpt@", "openai@", "claude@", etc.

## Policy Compliance

This action helps ensure compliance with Camunda's AI Policy by:

1. **Blocking direct AI authorship**: Prevents commits directly authored by AI tools
2. **Encouraging proper attribution**: Ensures humans are credited as commit authors
3. **Maintaining transparency**: Makes AI usage visible through proper attribution

## Best Practices

When using AI tools for code assistance:

1. **Human authorship**: Always ensure the human developer is the commit author
2. **Proper review**: Review AI-generated code before committing
3. **Attribution in commit messages**: If desired, mention AI assistance in commit messages (but not as co-author)
4. **Example of proper usage**:
   ```
   Author: John Doe <john.doe@camunda.com>

   feat: implement new feature

   Added new authentication logic with assistance from GitHub Copilot
   ```

## Error Messages

When AI-authored commits are detected, the action will:
- List the specific patterns that were found
- Show the commit hash and details
- Provide guidance on how to fix the issue
- Reference the AI Policy for context

## False Positives

If you believe the action is incorrectly flagging legitimate commits, please:
1. Check if the commit author/committer contains AI-related terms
2. Verify there are no AI co-author trailers

## Related Actions

- [assert-camunda-git-emails](../assert-camunda-git-emails/README.md) - Ensures only Camunda email addresses are used
- Both actions work together to ensure proper commit attribution and compliance
