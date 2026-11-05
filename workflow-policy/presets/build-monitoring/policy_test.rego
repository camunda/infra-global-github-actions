package workflow_policy.build_monitoring_test

import data.workflow_policy.build_monitoring

params := {"build-monitoring": {
	"first-step": "acme/start",
	"last-step-any-of": ["acme/submit", "./.github/actions/observe"],
}}

start := {"uses": "acme/start@0123456789012345678901234567890123456789"}

submit := {"uses": "acme/submit@v1", "if": "always()", "continue-on-error": true}

messages(steps) := {finding.msg |
	some finding in build_monitoring.deny with input as {"jobs": {"build": {"steps": steps}}}
		with data.params as params
}

test_direct_submission_passes if {
	count(messages([start, {"run": "make"}, submit])) == 0
}

test_local_wrapper_with_expression_passes if {
	observer := {"uses": "./.github/actions/observe", "if": "${{ always() }}", "continue-on-error": true}
	count(messages([start, {"uses": "actions/checkout@v5"}, observer])) == 0
}

test_monitor_after_another_step_fails if {
	messages([{"uses": "actions/checkout@v5"}, start, submit]) == {
		"job build: first step must use acme/start",
	}
}

test_run_step_first_fails if {
	messages([{"run": "make"}, start, submit]) == {"job build: first step must use acme/start"}
}

test_missing_observer_fails if {
	messages([start, {"run": "make"}]) == {
		"job build: last step must use one of acme/submit, ./.github/actions/observe",
	}
}

test_submission_without_always_fails if {
	messages([start, {"uses": "acme/submit@v1", "continue-on-error": true}]) == {
		"job build: last step must set if: always() and continue-on-error: true",
	}
}

test_submission_that_can_fail_the_job_fails if {
	messages([start, {"uses": "acme/submit@v1", "if": "always()"}]) == {
		"job build: last step must set if: always() and continue-on-error: true",
	}
}

test_job_without_steps_fails_both_checks if {
	messages([]) == {
		"job build: first step must use acme/start",
		"job build: last step must use one of acme/submit, ./.github/actions/observe",
	}
}
