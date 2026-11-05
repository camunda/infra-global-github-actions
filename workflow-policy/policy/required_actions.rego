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
	split(step.uses, "@")[0] == action
}

finding(job_id, action) := {
	"rule": "required-actions",
	"job": job_id,
	"action": action,
	"msg": sprintf("job %s is missing required action %s", [job_id, action]),
}
