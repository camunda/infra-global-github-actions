package workflow_policy.build_monitoring

# Rule contract: input is one workflow whose jobs all have steps; check.py applies
# exceptions to the findings afterwards. Each finding carries rule, job, and msg.

params := data.params["build-monitoring"]

deny contains finding(job_id, sprintf("first step must use %s", [params["first-step"]])) if {
	some job_id, _ in input.jobs
	not starts_with_monitor(job_id)
}

deny contains finding(job_id, sprintf("last step must use one of %s", [concat(", ", params["last-step-any-of"])])) if {
	some job_id, _ in input.jobs
	not ends_with_observer(job_id)
}

deny contains finding(job_id, "last step must set if: always() and continue-on-error: true") if {
	some job_id, _ in input.jobs
	ends_with_observer(job_id)
	not best_effort(last_step(job_id))
}

# Negate a helper rule, never a comparison holding a call: `not f(x) == y` is skipped
# silently when f(x) is undefined, such as for a `run:` step or a job without steps.
starts_with_monitor(job_id) if uses(params["first-step"], input.jobs[job_id].steps[0])

ends_with_observer(job_id) if {
	some pattern in params["last-step-any-of"]
	uses(pattern, last_step(job_id))
}

best_effort(step) if {
	contains(step["if"], "always()")
	step["continue-on-error"] == true
}

last_step(job_id) := input.jobs[job_id].steps[count(input.jobs[job_id].steps) - 1]

action(step) := split(step.uses, "@")[0] if is_string(step.uses)

# `*` matches one path segment, `**` any number including none (OPA 1.21+ needs `/**/` as `/`).
uses(pattern, step) if glob.match(pattern, ["/"], action(step))

uses(pattern, step) if glob.match(replace(pattern, "/**/", "/"), ["/"], action(step))

# Not named `violation`: Conftest evaluates every deny*, warn*, and violation* rule.
finding(job_id, msg) := {
	"rule": "build-monitoring",
	"job": job_id,
	"msg": sprintf("job %s: %s", [job_id, msg]),
}
