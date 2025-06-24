# Auto-Releases
This collection of github actions is currently intended to enable `Auto-Releases` on repositories. It's called `pull-request` because both actions can be used separately on manipulating pull requests.

If applied correctly, every commit to the mainline branch of a repository will be [added to a Release PR](./release/README.md) which then can be [automerged](./automerge/README.md) on a schedule.

## Available Actions

This package contains three complementary actions for pull request management:

* **[Release](./release/README.md)** - Automated release PR creation and management based on conventional commits
* **[Automerge](./automerge/README.md)** - Automated merging of release PRs on a schedule
* **[Validate Title](./validate-title/README.md)** - Validates PR titles against conventional commit format (recommended for projects which use release-please to manage releases)

## PR Title Validation for Projects Using Release-Please

⚠️ **Important for Projects Using Release-Please**: If your repository uses the release action and "Squash & Merge" strategy, it's highly recommended to also use the [validate-title](./validate-title/README.md) action. This prevents broken releases when PR titles don't follow conventional commit format. This is especially important when at the time of PR creation there is already more than 1 commit, as GitHub may generate a title which diverges from any convention.

```yaml
# .github/workflows/validate-pr-title.yml
name: Validate PR Title
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
jobs:
  validate-title:
    runs-on: ubuntu-latest
    steps:
      - uses: camunda/infra-global-github-actions/teams/infra/pull-request/validate-title@main
```

## Architecture
The `release` action leverages the [release-please-action](https://github.com/googleapis/release-please-action) to manage these release PRs.
It is handling the creation and updates of mentioned release PRs and the "bumping" of versions based on conventional commits. When a release PR gets merged release-please handles the creation of a new Github Release, the respective tag and a the management of the changelog file.

It can also handle monorepos with multiple packages, but we'll come to that later on.

## How to Integrate
To integrate the `Auto-Release` functionality you need the following basics:

* A release-please-config file ([example](./release/release-please-config.json)) which controls the behavior of how release-please acts when managing releases. It contains
  * A list of commit-prefixes to listen to
  * A list of packages to be released (or only `.` if it's not a monorepo)
  * General and package-specific configuration on how to create release tags
* A release-please-manifest file which contains the latest released version number of each package
* 2 workflow files
  * `release.yml` - gets triggered on pushes to the mainline branch and calls `release-please` under the hood. You can just copy [the example]()
  * `automerge.yml` - ideally a cronjob (e.g. `weekly`) which leverages `pascalgn/automerge-action` to merge. You can just copy [the example](./automerge/README.md) from the readme into your workflows folder.

Once everything got merged, you'll see a new release PR which you can merge directly or wait for the automerge workflow to do it.

## Integration Examples
* Simple release: https://github.com/camunda/infra-k8s-webhook/pull/86
* Monorepo Example: https://github.com/camunda/camunda-docker-ci-postgresql/pull/29

## Pre-Commit Hook & PR Title Validation
Since release-please depends on [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) to bump versions appropriately it's required to enforce the usage of these by pre-commit hooks. Just look at one of the above's examples to see how it's done.
