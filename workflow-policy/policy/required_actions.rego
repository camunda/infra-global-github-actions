package main

deny contains violation if {
	selected := data.selection[data.conftest.file.name]
	some job_id in selected.jobs
	job := input.jobs[job_id]
	not job.uses
	some action in data.required_actions
	not has_action(job, action)
	violation := {
		"msg": sprintf("job %s is missing required action %s", [job_id, action]),
		"kind": "missing-action",
		"job": job_id,
		"action": action,
		"_loc": {"file": selected.path, "line": 1},
	}
}

deny contains violation if {
	selected := data.selection[data.conftest.file.name]
	some job_id in selected.jobs
	input.jobs[job_id].uses
	violation := {
		"msg": sprintf(
			"job %s calls a reusable workflow; inspect it separately and add an explicit exception",
			[job_id],
		),
		"kind": "reusable-workflow",
		"job": job_id,
		"_loc": {"file": selected.path, "line": 1},
	}
}

has_action(job, action) if {
	some step in job.steps
	is_string(step.uses)
	split(step.uses, "@")[0] == action
}
