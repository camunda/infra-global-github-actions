// Adds issues and pull requests of Monorepo OS pilot users to the Monorepo OS board and sets their Due Date.
// The rules are in README.md; decide() holds them, run() applies them to the board.

// Pilot users by GitHub login: Engineering Operations for now.
const ROSTER = ["cmur2", "liliancavalet", "maxdanilov", "szpraat", "yanavasileva"];

const ISSUE_DAYS = 10;
const PR_DAYS = 2;
const DUE_DATE_FIELD = "Due Date";
// The search API allows 30 requests per minute.
const SEARCH_PAUSE_MS = 2100;

function inRoster(login, roster = ROSTER) {
  return !!login && roster.some((r) => r.toLowerCase() === login.toLowerCase());
}

/** The date `days` business days (Monday to Friday) after `start`, as YYYY-MM-DD. */
function addBusinessDays(start, days) {
  const d = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), start.getUTCDate()));
  let left = days;
  while (left > 0) {
    d.setUTCDate(d.getUTCDate() + 1);
    const weekday = d.getUTCDay();
    if (weekday !== 0 && weekday !== 6) left--;
  }
  return d.toISOString().slice(0, 10);
}

/**
 * What an event means for the board: `{ contentId, days, reset }`, or `{ skip }` with the reason.
 * `reset` replaces an existing Due Date; otherwise only an empty one is set, so dates humans set or removed stay.
 */
function decide(eventName, payload, roster = ROSTER) {
  const has = (login) => inRoster(login, roster);
  if (eventName === "issues") {
    const issue = payload.issue;
    if (payload.action !== "assigned") return { skip: `issue ${payload.action}` };
    if (issue.state !== "open") return { skip: "issue is closed" };
    if (!has(payload.assignee?.login)) return { skip: `assignee ${payload.assignee?.login} is not a pilot user` };
    return { contentId: issue.node_id, days: ISSUE_DAYS, reset: false };
  }

  const pr = payload.pull_request;
  if (!pr) return { skip: `unsupported event ${eventName}` };
  if (pr.state !== "open") return { skip: "pull request is closed" };
  if (pr.draft) return { skip: "pull request is a draft" };

  if (eventName === "pull_request") {
    switch (payload.action) {
      case "review_requested":
        // A team request carries requested_team instead and names no person.
        if (!has(payload.requested_reviewer?.login)) return { skip: "requested reviewer is not a pilot user" };
        return { contentId: pr.node_id, days: PR_DAYS, reset: true };
      case "opened":
      case "reopened":
      case "ready_for_review": {
        const involved = [pr.user?.login, ...(pr.requested_reviewers ?? []).map((r) => r.login)];
        if (!involved.some(has)) return { skip: "no pilot user authored it or is requested to review" };
        return {
          contentId: pr.node_id,
          days: PR_DAYS,
          reset: false,
          assign: authorToAssign(pr, payload.repository?.full_name, has),
        };
      }
      default:
        return { skip: `pull request ${payload.action}` };
    }
  }

  if (eventName === "pull_request_review") {
    if (payload.action !== "submitted" || payload.review?.state?.toLowerCase() !== "approved") {
      return { skip: "not an approval" };
    }
    const owners = [pr.user?.login, ...(pr.assignees ?? []).map((a) => a.login)];
    if (!owners.some(has)) return { skip: "no pilot user authored it or is assigned" };
    return { contentId: pr.node_id, days: PR_DAYS, reset: true };
  }

  return { skip: `unsupported event ${eventName}` };
}

/**
 * A pilot user's pull request without assignees gets its author assigned, so the author owns the merge like an issue
 * assignee owns the issue. An existing assignee is never replaced.
 */
function authorToAssign(pr, repository, has) {
  const author = pr.user?.login;
  if (!has(author) || (pr.assignees ?? []).length > 0 || !repository) return undefined;
  return { repository, number: pr.number, login: author };
}

/** The searches a backfill runs per pilot user, with the rule each result gets. */
function backfillSearches(repository, login) {
  return [
    { q: `repo:${repository} is:issue is:open assignee:${login}`, days: ISSUE_DAYS },
    { q: `repo:${repository} is:pr is:open draft:false author:${login}`, days: PR_DAYS },
    { q: `repo:${repository} is:pr is:open draft:false review-requested:${login}`, days: PR_DAYS },
  ];
}

function parseProjectUrl(url) {
  const match = /^https:\/\/github\.com\/orgs\/([^/]+)\/projects\/(\d+)\/?$/.exec(url ?? "");
  if (!match) throw new Error(`project-url must look like https://github.com/orgs/<org>/projects/<number>, got ${url}`);
  return { org: match[1], number: Number(match[2]) };
}

async function loadBoard(github, projectUrl) {
  const { org, number } = parseProjectUrl(projectUrl);
  const res = await github.graphql(
    `query($org: String!, $number: Int!, $field: String!) {
      organization(login: $org) {
        projectV2(number: $number) {
          id
          field(name: $field) { ... on ProjectV2Field { id dataType } }
        }
      }
    }`,
    { org, number, field: DUE_DATE_FIELD },
  );
  const project = res.organization.projectV2;
  if (project?.field?.dataType !== "DATE") throw new Error(`${projectUrl} has no date field "${DUE_DATE_FIELD}"`);
  return { projectId: project.id, dueFieldId: project.field.id };
}

/** Adds the content to the board (a no-op when it is already there) and sets its Due Date per the rule. */
async function apply(github, core, board, { contentId, days, reset, assign }, today, dryRun) {
  const due = addBusinessDays(today, days);
  if (dryRun) {
    const assigning = assign ? `, assign @${assign.login} to ${assign.repository}#${assign.number}` : "";
    core.info(`Dry run: would add ${contentId}${assigning} and set Due Date ${due}${reset ? "" : " if empty"}`);
    return;
  }
  if (assign) {
    const [owner, repo] = assign.repository.split("/");
    await github.rest.issues.addAssignees({ owner, repo, issue_number: assign.number, assignees: [assign.login] });
    core.info(`Assigned @${assign.login} to ${assign.repository}#${assign.number}`);
  }
  const added = await github.graphql(
    `mutation($project: ID!, $content: ID!, $field: String!) {
      addProjectV2ItemById(input: { projectId: $project, contentId: $content }) {
        item { id fieldValueByName(name: $field) { ... on ProjectV2ItemFieldDateValue { date } } }
      }
    }`,
    { project: board.projectId, content: contentId, field: DUE_DATE_FIELD },
  );
  const item = added.addProjectV2ItemById.item;
  const current = item.fieldValueByName?.date;
  if (current && !reset) {
    core.info(`${contentId} is on the board, keeping its Due Date ${current}`);
    return;
  }
  await github.graphql(
    `mutation($project: ID!, $item: ID!, $field: ID!, $date: Date!) {
      updateProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field, value: { date: $date } }) {
        projectV2Item { id }
      }
    }`,
    { project: board.projectId, item: item.id, field: board.dueFieldId, date: due },
  );
  core.info(`${contentId} is on the board, Due Date ${current ?? "empty"} → ${due}`);
}

async function backfill(github, core, board, repository, today, dryRun, sleep) {
  const seen = new Set();
  for (const login of ROSTER) {
    for (const { q, days } of backfillSearches(repository, login)) {
      const results = await github.paginate(github.rest.search.issuesAndPullRequests, { q, per_page: 100 });
      await sleep(SEARCH_PAUSE_MS);
      for (const result of results) {
        if (seen.has(result.node_id)) continue;
        seen.add(result.node_id);
        core.info(`${result.html_url}`);
        const assign = result.pull_request ? authorToAssign(result, repository, (l) => inRoster(l)) : undefined;
        await apply(github, core, board, { contentId: result.node_id, days, reset: false, assign }, today, dryRun);
      }
    }
  }
  core.info(`Backfill of ${repository}: ${seen.size} issues and pull requests`);
}

async function run({ github, context, core, projectUrl, dryRun, now = new Date(), sleep }) {
  sleep ??= (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  if (context.eventName === "workflow_dispatch") {
    const board = await loadBoard(github, projectUrl);
    await backfill(github, core, board, `${context.repo.owner}/${context.repo.repo}`, now, dryRun, sleep);
    return;
  }
  const decision = decide(context.eventName, context.payload);
  if (decision.skip) {
    core.info(`Skipped: ${decision.skip}`);
    return;
  }
  await apply(github, core, await loadBoard(github, projectUrl), decision, now, dryRun);
}

module.exports = { addBusinessDays, decide, backfillSearches, parseProjectUrl, run };
