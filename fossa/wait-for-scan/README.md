# FOSSA Wait for Scan

This action waits for a FOSSA scan to complete before proceeding. It's designed to be used between the `fossa/analyze` and `fossa/release` actions to ensure the scan has finished before creating releases and generating reports.

## Usage

```yaml
- name: Wait for FOSSA scan completion
  uses: ./fossa/wait-for-scan
  with:
    api-key: ${{ secrets.FOSSA_API_KEY }}
    project-id: 'custom+50756/camunda-cloud/identity'
    branch: ${{ github.ref_name }}
    revision-id: ${{ github.sha }}
    timeout: 600  # optional, default 10 minutes
    poll-interval: 30  # optional, default 30 seconds
    dry-run: 'false'  # optional, default false
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `api-key` | The API key to access fossa.com | Yes | - |
| `project-id` | Project ID (locator) | Yes | - |
| `branch` | Name of the branch | Yes | - |
| `revision-id` | Git commit hash of the scanned revision | Yes | - |
| `timeout` | Maximum time to wait for scan completion in seconds | No | `600` (10 min) |
| `poll-interval` | Seconds between status checks | No | `30` |
| `dry-run` | Enable dry-run mode (print commands without executing) | No | `'false'` |

## How it works

This action uses FOSSA's revisions endpoint to check for scan completion:

1. **After `fossa analyze`**: Revision exists but analysis is still in progress
2. **When analysis completes**: Revision shows `resolved: true` with scan data
3. **This action waits**: For the revision to be fully resolved with results

**Implementation**:
1. Builds a locator in the format `{project-id}${revision-id}`
2. URL-encodes the locator ($ → %24, + → %2B, / → %2F)
3. Polls the FOSSA `/api/revisions/{encoded-locator}` endpoint
4. Checks multiple completion criteria:
   - `resolved: true` - analysis is complete
   - `dependency_count > 0` - dependencies were found and analyzed
   - `revisionScans.length > 0` - scan results are available
5. Exits successfully when all criteria are met
6. Times out if analysis doesn't complete within the specified timeout period

This approach directly queries the revision status rather than inferring completion from build counts, providing more reliable and accurate completion detection.

## Workflow Integration

Use this action in the following sequence:

```yaml
- name: Run FOSSA analysis
  uses: ./fossa/analyze
  with:
    # ... analyze inputs

- name: Wait for scan completion
  uses: ./fossa/wait-for-scan
  with:
    # ... wait inputs

- name: Create FOSSA release and generate reports
  uses: ./fossa/release
  with:
    # ... release inputs
```

## Error Handling

- **Timeout**: If analysis doesn't complete within the specified timeout period, the action will exit with an error
- **API Errors**: Non-200 HTTP responses cause immediate failure (no retries) - indicates authentication, authorization, or server issues

## Dry-Run Mode

Enable `dry-run: 'true'` to see what the action would do without making actual API calls:

```yaml
- name: Test wait-for-scan configuration
  uses: ./fossa/wait-for-scan
  with:
    api-key: ${{ secrets.FOSSA_API_KEY }}
    project-id: 'custom+50756/camunda-cloud/identity'
    branch: ${{ github.ref_name }}
    revision-id: ${{ github.sha }}
    dry-run: 'true'
```

**Dry-run output includes**:
- All configuration parameters
- The exact API endpoint URL
- curl command structure (with redacted API key)
- Polling behavior description
- Success exit without waiting
