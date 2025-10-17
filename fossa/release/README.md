# FOSSA Create Release and Reports

This action creates FOSSA releases and generates attribution and SBOM reports to different release groups with configurable formats.

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
| `attribution-format` | Format for attribution report (e.g., TXT, HTML) | No | `TXT` |
| `sbom-format` | Format for SBOM report (e.g., CYCLONEDX_JSON, SPDX_JSON) | No | `CYCLONEDX_JSON` |
| `generate-attribution` | Whether to generate attribution report | No | `true` |
| `generate-sbom` | Whether to generate SBOM report | No | `true` |

- Release Group is a [FOSSA concept](https://docs.fossa.com/docs/release-groups) to organize releases. Among others, they're used to publish different report types (attribution, SBOM) to different audiences (internal, public).
- An SBOM (Software Bill of Materials) details a comprehensive list of all software components (including open source and proprietary libraries) that make up your application. They are essential for identifying vulnerabilities, managing dependencies, and sharing component inventories with partners, auditors, or customers.
- Attribution reports are focused on license compliance and proper acknowledgment of open source software authors.
- At the time of writing, each release can only publish one report type and format, so this action creates separate releases for attribution and SBOM reports.
- This action assumes that the specified release groups already exist in FOSSA. As these groups are typically set up once per project, you can create them manually in the FOSSA web app or via the API, having the proper access rights.

Notes on choosing the branch
- Although FOSSA allows releases to be created on any branch, it's recommended to use a dedicated release branch (e.g., `release/8.x`) rather than feature branches. This ensures that reports are consistently associated with stable release versions.

## How it works

This action creates separate releases in different release groups and generates reports from each:

1. **Creates 2 releases**: One in the attribution group, one in the SBOM group
2. **Gets 2 release IDs**: Each release has its own unique ID within its group
3. **Generates attribution report**: Uses the attribution release ID and publishes to attribution group
4. **Generates SBOM report**: Uses the SBOM release ID and publishes to SBOM group

**Implementation**:
1. Loops through release groups to create releases in sequential workflow
2. Stores release IDs as step outputs (`attribution-release-id`, `sbom-release-id`)
3. Loops through report types to generate reports using appropriate release IDs
4. Each report is published to its designated release group in the specified format
5. All FOSSA report options are enabled (deep dependencies, licenses, vulnerabilities, etc.)

## Supported Formats

See [FOSSA API documentation](https://docs.fossa.com/reference/queuereleasegroupattributionreport) for all supported formats.

**Common formats**:
- `TXT` - Plain text attribution report
- `HTML` - HTML attribution report
- `CYCLONEDX_JSON` - CycloneDX SBOM in JSON format
- `SPDX_JSON` - SPDX SBOM in JSON format
- `CSV` - CSV format report

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
