# FOSSA Create Release and Reports

This action creates FOSSA releases, generates attribution and SBOM reports to different release groups with configurable formats, waits for publication to complete, and optionally sends Slack notifications on timeout.

## Usage

```yaml
- name: Create FOSSA release and generate reports
  uses: ./fossa/release
  with:
    api-key: ${{ secrets.FOSSA_API_KEY }}
    attribution-release-group-id: '1234'
    sbom-release-group-id: '5678'
    release-number: '8.8.0'
    project-id: 'custom+50756/camunda-cloud/identity'
    branch: ${{ github.ref_name }}
    revision-id: ${{ github.sha }}
    attribution-format: 'TXT'  # optional, default TXT
    sbom-format: 'CYCLONEDX_JSON'  # optional, default CYCLONEDX_JSON
    generate-attribution: 'true'  # optional, default true
    generate-sbom: 'true'  # optional, default true
    slack-notify: 'true'  # optional, default false
    slack-webhook-infra-alerts: ${{ secrets.SLACK_WEBHOOK_INFRA_ALERTS }}  # required if slack-notify is true
    dry-run: 'false'  # optional, default false
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `api-key` | The API key to access fossa.com | Yes | - |
| `attribution-release-group-id` | Release group ID for attribution reports | Yes | - |
| `sbom-release-group-id` | Release group ID for SBOM reports | Yes | - |
| `release-number` | Version number of the release to be created | Yes | - |
| `project-id` | Project ID (locator) | Yes | - |
| `branch` | Name of the (release) branch | Yes | - |
| `revision-id` | Git commit hash of the scanned revision | Yes | - |
| `attribution-format` | Format for attribution report (TXT or CYCLONEDX_JSON) | No | `TXT` |
| `sbom-format` | Format for SBOM report (TXT or CYCLONEDX_JSON) | No | `CYCLONEDX_JSON` |
| `generate-attribution` | Whether to generate attribution report | No | `true` |
| `generate-sbom` | Whether to generate SBOM report | No | `true` |
| `slack-notify` | Send Slack notifications on publication timeout | No | `false` |
| `slack-webhook-infra-alerts` | Slack webhook URL for infrastructure alerts | No | - |
| `dry-run` | Enable dry-run mode (print commands without executing) | No | `'false'` |

- Release Group is a [FOSSA concept](https://docs.fossa.com/docs/release-groups) to organize releases. Among others, they're used to publish different report types (attribution, SBOM) to different audiences (internal, public).
- An SBOM (Software Bill of Materials) details a comprehensive list of all software components (including open source and proprietary libraries) that make up your application. They are essential for identifying vulnerabilities, managing dependencies, and sharing component inventories with partners, auditors, or customers.
- Attribution reports are focused on license compliance and proper acknowledgment of open source software authors.
- At the time of writing, each release can only publish one report type and format, so this action creates separate releases for attribution and SBOM reports.
- This action assumes that the specified release groups already exist in FOSSA. As these groups are typically set up once per project, you can create them manually in the FOSSA web app or via the API, having the proper access rights.

Notes on choosing the branch
- Although FOSSA allows releases to be created on any branch, it's recommended to use a dedicated release branch (e.g., `release/8.x`) rather than feature branches. This ensures that reports are consistently associated with stable release versions.

## How it works

This action creates separate releases in different release groups, generates reports from each, and waits for publication to complete:

1. **Creates 2 releases**: One in the attribution group, one in the SBOM group
2. **Gets 2 release IDs**: Each release has its own unique ID within its group
3. **Generates attribution report**: Uses the attribution release ID and publishes to attribution group
4. **Generates SBOM report**: Uses the SBOM release ID and publishes to SBOM group
5. **Waits for publication**: Polls both release groups in parallel (up to 5 minutes) to verify reports are published
6. **Sends Slack notification**: (Optional) Alerts on publication timeout with actionable details

**Implementation**:
1. Loops through release groups to create releases in sequential workflow
2. Stores release IDs as step outputs (`attribution-release-id`, `sbom-release-id`)
3. Loops through report types to generate reports using appropriate release IDs
4. Each report is published to its designated release group in the specified format
5. All FOSSA report options are enabled (deep dependencies, licenses, vulnerabilities, etc.)
6. Polls both release groups concurrently to check publication status every 10 seconds
7. If timeout occurs, logs warnings and optionally sends Slack notification with report status

## Supported Formats

**Currently supported formats** (verified by polling mechanism):
- `TXT` - Plain text attribution report (API status: `attribution_txt`)
- `CYCLONEDX_JSON` - CycloneDX SBOM in JSON format (API status: `cyclonedx_json`)

See [FOSSA API documentation](https://docs.fossa.com/reference/queuereleasegroupattributionreport) for all available formats. Note: Other formats may work for report generation but are not validated by the publication polling step.

## Workflow Integration

Use this action after `fossa/wait-for-scan`:

```yaml
- name: Run FOSSA analysis
  uses: camunda/infra-global-github-actions/fossa/analyze@<commit-sha>
  with:
    # ... analyze inputs

- name: Wait for scan completion
  uses: camunda/infra-global-github-actions/fossa/wait-for-scan@<commit-sha>
  with:
    # ... wait inputs

- name: Create releases and generate reports
  uses: camunda/infra-global-github-actions/fossa/release@<commit-sha>
  with:
    attribution-release-group-id: 'internal-group'
    sbom-release-group-id: 'public-group'
    # ... other inputs
```

## Error Handling

- **API Failures**: HTTP errors cause immediate failure with response details
- **Missing Release IDs**: Validation ensures release creation succeeded before report generation
- **Conditional Execution**: Reports only generate if release creation succeeds
- **Publication Timeout**: If reports don't publish within 5 minutes, workflow continues with warning (doesn't fail)
- **Slack Notifications**: Optional alerts sent when publication timeout occurs

## Publication Polling

After generating reports, the action waits for them to be published on the FOSSA portal:

- **Timeout**: Maximum 5 minutes (300 seconds)
- **Poll Interval**: Every 10 seconds (30 attempts total)
- **Parallel Execution**: Both attribution and SBOM reports are polled simultaneously
- **Status Checking**: Monitors the `publishedOnPortal` field in the FOSSA API response
  - `null` or `pending`: Report is still being processed
  - `attribution_txt` or `cyclonedx_json`: Report successfully published
- **Workflow Behavior**: On timeout, the workflow continues (doesn't fail) but logs warnings

## Slack Notifications

Enable Slack notifications to get alerted when reports fail to publish within the timeout period:

```yaml
- name: Create FOSSA release with Slack alerts
  uses: ./fossa/release
  with:
    api-key: ${{ secrets.FOSSA_API_KEY }}
    attribution-release-group-id: '1234'
    sbom-release-group-id: '5678'
    release-number: '8.8.0'
    project-id: 'custom+50756/camunda-cloud/identity'
    branch: ${{ github.ref_name }}
    revision-id: ${{ github.sha }}
    slack-notify: 'true'
    slack-webhook-infra-alerts: ${{ secrets.SLACK_WEBHOOK_INFRA_ALERTS }}
```

**Notification includes**:
- Repository, release number, branch, and workflow run link
- Status of each report (✓ published or ⚠️ timeout)
- Direct links to FOSSA release groups for manual checking
- Link to internal handbook for troubleshooting
- Mention of `@infra-medic` for team awareness

**When notifications are sent**:
- Only when `slack-notify: 'true'` is set
- Only when one or more reports fail to publish within the timeout
- Never sent in dry-run mode

## Dry-Run Mode

Enable `dry-run: 'true'` to see what the action would do without making actual API calls:

```yaml
- name: Test release configuration
  uses: ./fossa/release
  with:
    api-key: ${{ secrets.FOSSA_API_KEY }}
    attribution-release-group-id: '1234'
    sbom-release-group-id: '5678'
    release-number: '8.8.0'
    project-id: 'custom+50756/camunda-cloud/identity'
    branch: ${{ github.ref_name }}
    revision-id: ${{ github.sha }}
    dry-run: 'true'
```

**Dry-run output includes**:
- **Release creation**: POST request details, headers, and JSON payload for each release group
- **Mock release IDs**: Generates fake IDs (`mock-attribution-release-id-12345`, `mock-sbom-release-id-12345`) for testing
- **Report generation**: POST request URLs with all query parameters for each report type
- **Publication polling**: Shows what would be polled without making actual API calls
- **Configuration validation**: Ensures all inputs are correctly formatted

Note: Slack notifications are never sent in dry-run mode.
