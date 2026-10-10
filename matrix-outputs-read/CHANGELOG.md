# Changelog

## 1.0.1 (2026-10-10)

## What's Changed
* fix(actionlint): install from verified release assets instead of curl | bash by @leiicamundi in https://github.com/camunda/infra-global-github-actions/pull/789
* fix(renovate): match the actual packageName for pre-commit automerge by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/788
* chore(deps): update dependency pre-commit to v4.6.2 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/786
* chore(deps): update codex-/return-dispatch action to v4 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/772
* chore(deps): update mikefarah/yq action to v4.53.6 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/793
* chore(deps): update docker/setup-buildx-action action to v4.3.0 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/795
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.39.1 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/796
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/790
* chore(deps): update dependency fossas/fossa-cli to v3.18.1 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/794
* docs(submit-aborted-gha-status): clarify shutdown-signal filtering and OOM reconciliation by @clementnero in https://github.com/camunda/infra-global-github-actions/pull/798
* chore(deps): update dependency fossas/fossa-cli to v3.18.2 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/799
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.50.3 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/800
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.51.0 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/801
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/797
* chore(deps): update docker/setup-qemu-action action to v4.3.0 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/802
* chore(deps): update pre-commit hooks by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/803
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/805
* chore(deps): update s4u/setup-maven-action action to v1.21.0 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/804
* feat(automerge): add opt-in author filter by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/807
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/806
* fix(preview-env): stop word splitting shattering PR JSON in clean job by @szpraat in https://github.com/camunda/infra-global-github-actions/pull/808
* feat(renovate): add preset tracking per-action release versions by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/810
* feat(release): onboard all remaining root-level actions to release-please by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/811
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/809
* docs: document the Renovate preset and restructure the README by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/812
* feat: add ability to switch to ARM-based FOSSA CLI by @Kerruba in https://github.com/camunda/infra-global-github-actions/pull/813
* chore: adds bootstrap-sha to support first release of kubernetes-image-replace and fix FOSSA release by @Kerruba in https://github.com/camunda/infra-global-github-actions/pull/814
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/815
* chore(deps): update dependency fossas/fossa-cli to v3.18.4 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/816
* chore(deps): update pre-commit hooks by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/817
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/818
* fix(fossa): survive a reset connection when downloading the FOSSA CLI by @yanavasileva in https://github.com/camunda/infra-global-github-actions/pull/819
* docs(submit-test-status): document the test_status values producers actually send by @cmur2 in https://github.com/camunda/infra-global-github-actions/pull/821
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/820
* docs(submit-test-status): document test_status meanings by @cmur2 in https://github.com/camunda/infra-global-github-actions/pull/822
* docs: lead vault-action examples with JWT auth by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/824
* fix: migrate Vault auth from AppRole to JWT/OIDC by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/825
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/823
* chore(deps): update docker/build-push-action action to v7.4.0 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/827
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.103.1 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/830
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/831
* chore(deps): update docker/setup-qemu-action action to v4.4.0 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/829
* chore(deps): update docker/setup-buildx-action action to v4.4.1 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/828
* fix(fossa): use curl's default exponential backoff on retry by @yanavasileva in https://github.com/camunda/infra-global-github-actions/pull/826
* fix(actionlint): accept ubuntu-26.04 as a valid runner label by @wollefitz in https://github.com/camunda/infra-global-github-actions/pull/834
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/833
* fix: stamp CI Analytics report_time in UTC by @cmur2 in https://github.com/camunda/infra-global-github-actions/pull/835
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/836
* chore(deps): update dependency ubuntu to v26 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/832
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.115.9 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/839
* chore(deps): update argocd cli to v3.5.3 by @clementnero in https://github.com/camunda/infra-global-github-actions/pull/842
* fix(fossa): retry transient GitHub API errors when fetching job info by @yanavasileva in https://github.com/camunda/infra-global-github-actions/pull/843
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/844
* chore(deps): update mikefarah/yq action to v4.54.1 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/845
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.132.2 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/846
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/847
* chore: include the build-duration-milliseconds github runner monitoring in the reusable workflow by @Kerruba in https://github.com/camunda/infra-global-github-actions/pull/751
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/848
* fix(submit-test-status): use $RUNNER_TEMP so container jobs work by @cmur2 in https://github.com/camunda/infra-global-github-actions/pull/850
* chore: release main by @infra-releases[bot] in https://github.com/camunda/infra-global-github-actions/pull/851
* chore(deps): update actions/download-artifact action to v8.0.2 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/855
* chore(deps): update actions/upload-artifact action to v7.0.2 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/856
* chore(deps): update quay.io/argoproj/argocd docker tag to v3.5.4 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/857
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.149.1 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/860

## New Contributors
* @yanavasileva made their first contribution in https://github.com/camunda/infra-global-github-actions/pull/819

**Full Changelog**: https://github.com/camunda/infra-global-github-actions/compare/matrix-outputs-read-1.0.0...matrix-outputs-read-1.0.1

## 1.0.0 (2026-08-15)

## What's Changed
* fix: pin vault-action and create-github-app-token to full-length SHAs by @leiicamundi in https://github.com/camunda/infra-global-github-actions/pull/779
* ci: pin every GitHub Action to a commit SHA and enforce it with zizmor by @kellervater in https://github.com/camunda/infra-global-github-actions/pull/781
* ci: inline pre-commit so the pinning gate can run by @leiicamundi in https://github.com/camunda/infra-global-github-actions/pull/783
* feat: add matrix-outputs-read by @leiicamundi in https://github.com/camunda/infra-global-github-actions/pull/784
* chore(deps): update pre-commit hook renovatebot/pre-commit-hooks to v44.30.2 by @renovate[bot] in https://github.com/camunda/infra-global-github-actions/pull/787


**Full Changelog**: https://github.com/camunda/infra-global-github-actions/compare/fossa-1.0.16...matrix-outputs-read-1.0.0
