package workflow_policy.required_actions

# Rule contract: input is one workflow whose jobs all have steps; check.py applies
# exceptions to the findings afterwards. Each finding carries rule, job, and msg.

deny contains finding(job_id, action) if {
	some job_id, job in input.jobs
	some action in data.params["required-actions"].actions
	not has_action(job, action)
}

has_action(job, action) if {
	some step in job.steps
	is_string(step.uses)
	matches(action, split(step.uses, "@")[0])
}

# `*` matches one path segment, `**` any number including none (OPA 1.21+ needs `/**/` as `/`).
matches(pattern, path) if glob.match(pattern, ["/"], path)

matches(pattern, path) if glob.match(replace(pattern, "/**/", "/"), ["/"], path)

finding(job_id, action) := {
	"rule": "required-actions",
	"job": job_id,
	"action": action,
	"msg": sprintf("job %s is missing required action %s", [job_id, action]),
}
