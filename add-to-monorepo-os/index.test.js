const test = require("node:test");
const assert = require("node:assert/strict");
const { addBusinessDays, decide, backfillSearches, parseProjectUrl, run } = require("./index.js");

const ROSTER = ["pilot", "Other-Pilot"];
const user = (login) => ({ login });
const issue = (overrides = {}) => ({ node_id: "I_1", state: "open", ...overrides });
const pr = (overrides = {}) => ({
  node_id: "PR_1",
  state: "open",
  draft: false,
  user: user("outsider"),
  requested_reviewers: [],
  assignees: [],
  ...overrides,
});

test("addBusinessDays skips weekends", () => {
  // 2026-11-13 is a Friday.
  assert.equal(addBusinessDays(new Date("2026-11-13T22:00:00Z"), 2), "2026-11-17");
  assert.equal(addBusinessDays(new Date("2026-11-11T08:00:00Z"), 10), "2026-11-25");
  // From a Saturday, the first business day is Monday.
  assert.equal(addBusinessDays(new Date("2026-11-14T08:00:00Z"), 1), "2026-11-16");
});

test("an issue is added with 10 days if empty when a pilot user is assigned", () => {
  const decision = decide("issues", { action: "assigned", issue: issue(), assignee: user("PILOT") }, ROSTER);
  assert.deepEqual(decision, { contentId: "I_1", days: 10, reset: false });
});

test("an issue assigned to someone else, or closed, or opened, is skipped", () => {
  assert.ok(decide("issues", { action: "assigned", issue: issue(), assignee: user("outsider") }, ROSTER).skip);
  assert.ok(decide("issues", { action: "assigned", issue: issue({ state: "closed" }), assignee: user("pilot") }, ROSTER).skip);
  assert.ok(decide("issues", { action: "opened", issue: issue() }, ROSTER).skip);
});

test("a review request for a pilot user resets the date to 2 days, re-requests included", () => {
  const payload = { action: "review_requested", pull_request: pr(), requested_reviewer: user("other-pilot") };
  assert.deepEqual(decide("pull_request", payload, ROSTER), { contentId: "PR_1", days: 2, reset: true });
});

test("a team review request is skipped", () => {
  const payload = { action: "review_requested", pull_request: pr(), requested_team: { slug: "engineering-operations" } };
  assert.ok(decide("pull_request", payload, ROSTER).skip);
});

const repository = { full_name: "camunda/x" };

test("a pull request by a pilot user is added with 2 days if empty and its author assigned", () => {
  for (const action of ["opened", "reopened", "ready_for_review"]) {
    const payload = { action, repository, pull_request: pr({ number: 7, user: user("pilot") }) };
    assert.deepEqual(decide("pull_request", payload, ROSTER), {
      contentId: "PR_1",
      days: 2,
      reset: false,
      assign: { repository: "camunda/x", number: 7, login: "pilot" },
    });
  }
});

test("an existing assignee is never replaced by the author", () => {
  const payload = { action: "opened", repository, pull_request: pr({ user: user("pilot"), assignees: [user("x")] }) };
  assert.equal(decide("pull_request", payload, ROSTER).assign, undefined);
});

test("a pull request leaving draft with a pilot user already requested is added without assigning its author", () => {
  const payload = { action: "ready_for_review", repository, pull_request: pr({ requested_reviewers: [user("pilot")] }) };
  const decision = decide("pull_request", payload, ROSTER);
  assert.equal(decision.contentId, "PR_1");
  assert.equal(decision.assign, undefined);
});

test("draft and closed pull requests are skipped", () => {
  const draft = { action: "review_requested", pull_request: pr({ draft: true }), requested_reviewer: user("pilot") };
  assert.ok(decide("pull_request", draft, ROSTER).skip);
  const closed = { action: "reopened", pull_request: pr({ state: "closed", user: user("pilot") }) };
  assert.ok(decide("pull_request", closed, ROSTER).skip);
});

test("an approval resets the date to 2 days when a pilot user authored it or is assigned", () => {
  const approved = { action: "submitted", review: { state: "approved" } };
  assert.deepEqual(decide("pull_request_review", { ...approved, pull_request: pr({ user: user("pilot") }) }, ROSTER), {
    contentId: "PR_1",
    days: 2,
    reset: true,
  });
  const assigned = { ...approved, pull_request: pr({ assignees: [user("pilot")] }) };
  assert.equal(decide("pull_request_review", assigned, ROSTER).reset, true);
});

test("a non-approving review, or an approval of an outsider's pull request, is skipped", () => {
  const comment = { action: "submitted", review: { state: "commented" }, pull_request: pr({ user: user("pilot") }) };
  assert.ok(decide("pull_request_review", comment, ROSTER).skip);
  const outsider = { action: "submitted", review: { state: "approved" }, pull_request: pr() };
  assert.ok(decide("pull_request_review", outsider, ROSTER).skip);
});

test("backfill searches open assigned issues, and authored and directly review-requested non-draft pull requests", () => {
  assert.deepEqual(
    backfillSearches("camunda/x", "pilot").map((s) => [s.q, s.days]),
    [
      ["repo:camunda/x is:issue is:open assignee:pilot", 10],
      ["repo:camunda/x is:pr is:open draft:false author:pilot", 2],
      ["repo:camunda/x is:pr is:open draft:false user-review-requested:pilot", 2],
    ],
  );
});

test("parseProjectUrl accepts org project URLs only", () => {
  assert.deepEqual(parseProjectUrl("https://github.com/orgs/camunda/projects/267"), { org: "camunda", number: 267 });
  assert.throws(() => parseProjectUrl("https://github.com/users/me/projects/1"));
});

// A fake GitHub client: one board with a Due Date field, items keyed by content ID.
function fakeGitHub(items = {}) {
  const calls = [];
  const graphql = async (query, vars) => {
    calls.push(query.match(/(organization|addProjectV2ItemById|updateProjectV2ItemFieldValue|items)\(/)[1]);
    if (query.includes("items(")) {
      const nodes = Object.keys(items).map((id) => ({ content: { id } }));
      return { node: { items: { nodes, pageInfo: { hasNextPage: false, endCursor: null } } } };
    }
    if (query.includes("organization(")) {
      return { organization: { projectV2: { id: "P", field: { id: "F", dataType: "DATE" } } } };
    }
    if (query.includes("addProjectV2ItemById")) {
      items[vars.content] ??= { id: `item-${vars.content}`, date: null };
      const item = items[vars.content];
      return { addProjectV2ItemById: { item: { id: item.id, fieldValueByName: item.date ? { date: item.date } : null } } };
    }
    const item = Object.values(items).find((i) => i.id === vars.item);
    item.date = vars.date;
    return { updateProjectV2ItemFieldValue: { projectV2Item: { id: item.id } } };
  };
  return { graphql, calls, items };
}
const core = { info: () => {} };
const wednesday = new Date("2026-11-11T08:00:00Z");
const projectUrl = "https://github.com/orgs/camunda/projects/289";

test("run sets the Due Date of a newly added item", async () => {
  const github = fakeGitHub();
  const context = {
    eventName: "pull_request",
    payload: { action: "review_requested", pull_request: pr(), requested_reviewer: user("cmur2") },
  };
  await run({ github, context, core, projectUrl, dryRun: false, now: wednesday });
  assert.equal(github.items.PR_1.date, "2026-11-13");
});

test("run keeps an existing Due Date unless the rule resets it", async () => {
  const github = fakeGitHub({ I_1: { id: "item-I_1", date: "2026-12-24" } });
  const context = { eventName: "issues", payload: { action: "assigned", issue: issue(), assignee: user("cmur2") } };
  await run({ github, context, core, projectUrl, dryRun: false, now: wednesday });
  assert.equal(github.items.I_1.date, "2026-12-24");

  const reset = fakeGitHub({ PR_1: { id: "item-PR_1", date: "2026-11-01" } });
  const approval = {
    eventName: "pull_request_review",
    payload: { action: "submitted", review: { state: "APPROVED" }, pull_request: pr({ user: user("cmur2") }) },
  };
  await run({ github: reset, context: approval, core, projectUrl, dryRun: false, now: wednesday });
  assert.equal(reset.items.PR_1.date, "2026-11-13");
});

test("run touches nothing for a skipped event, and writes nothing in a dry run", async () => {
  const skipped = fakeGitHub();
  const context = { eventName: "issues", payload: { action: "assigned", issue: issue(), assignee: user("outsider") } };
  await run({ github: skipped, context, core, projectUrl, dryRun: false, now: wednesday });
  assert.deepEqual(skipped.calls, []);

  const dry = fakeGitHub();
  const assigned = { eventName: "issues", payload: { action: "assigned", issue: issue(), assignee: user("cmur2") } };
  await run({ github: dry, context: assigned, core, projectUrl, dryRun: true, now: wednesday });
  assert.deepEqual(dry.calls, ["organization"]);
});

test("backfill adds each missing search result once and leaves items already on the board alone", async () => {
  // I_9 is on the board with its Due Date cleared by a human.
  const github = fakeGitHub({ I_9: { id: "item-I_9", date: null } });
  const queries = [];
  github.rest = { search: { issuesAndPullRequests: "search" } };
  github.paginate = async (_endpoint, { q }) => {
    queries.push(q);
    if (q.includes("assignee:cmur2")) return [{ node_id: "I_9", html_url: "i9" }];
    if (q.includes("is:pr") && (q.includes(":cmur2") || q.includes(":szpraat"))) {
      return [{ node_id: "PR_7", html_url: "pr7", number: 7, user: user("cmur2"), assignees: [], pull_request: {} }];
    }
    return [];
  };
  const assigned = [];
  github.rest.issues = { addAssignees: async (args) => assigned.push(args) };
  const context = { eventName: "workflow_dispatch", repo: { owner: "camunda", repo: "monorepo-os" }, payload: {} };
  await run({ github, context, core, projectUrl, dryRun: false, now: wednesday, sleep: async () => {} });
  assert.equal(github.items.I_9.date, null);
  assert.equal(github.items.PR_7.date, "2026-11-13");
  assert.equal(github.calls.filter((c) => c === "addProjectV2ItemById").length, 1);
  assert.ok(queries.every((q) => q.startsWith("repo:camunda/monorepo-os ")));
  assert.deepEqual(assigned, [{ owner: "camunda", repo: "monorepo-os", issue_number: 7, assignees: ["cmur2"] }]);
});

test("run assigns the author before adding the pull request", async () => {
  const github = fakeGitHub();
  const assigned = [];
  github.rest = { issues: { addAssignees: async (args) => assigned.push(args) } };
  const context = {
    eventName: "pull_request",
    payload: { action: "opened", repository: { full_name: "camunda/x" }, pull_request: pr({ number: 3, user: user("szpraat") }) },
  };
  await run({ github, context, core, projectUrl, dryRun: false, now: wednesday });
  assert.deepEqual(assigned, [{ owner: "camunda", repo: "x", issue_number: 3, assignees: ["szpraat"] }]);
  assert.equal(github.items.PR_1.date, "2026-11-13");
});
