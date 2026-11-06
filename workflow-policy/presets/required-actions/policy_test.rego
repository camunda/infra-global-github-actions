package workflow_policy.required_actions_test

import data.workflow_policy.required_actions

params := {"required-actions": {"actions": ["actions/checkout", "acme/tool/setup"]}}

messages(steps) := {finding.msg |
	some finding in required_actions.deny with input as {"jobs": {"build": {"steps": steps}}}
		with data.params as params
}

test_all_actions_at_any_ref_pass if {
	count(messages([
		{"uses": "actions/checkout@0123456789012345678901234567890123456789"},
		{"run": "make"},
		{"uses": "acme/tool/setup@v1"},
	])) == 0
}

test_each_missing_action_is_reported if {
	messages([{"run": "make"}]) == {
		"job build is missing required action actions/checkout",
		"job build is missing required action acme/tool/setup",
	}
}

pattern_messages(steps) := {finding.msg |
	some finding in required_actions.deny with input as {"jobs": {"build": {"steps": steps}}}
		with data.params as {"required-actions": {"actions": ["acme/*/setup"]}}
}

test_star_matches_one_path_segment if {
	count(pattern_messages([{"uses": "acme/tool/setup@v1"}])) == 0
	pattern_messages([{"uses": "acme/tool/extra/setup@v1"}]) == {
		"job build is missing required action acme/*/setup",
	}
}

double_star_messages(steps) := {finding.msg |
	some finding in required_actions.deny with input as {"jobs": {"build": {"steps": steps}}}
		with data.params as {"required-actions": {"actions": ["./**/.github/actions/setup"]}}
}

test_double_star_matches_any_number_of_segments_including_none if {
	every path in ["./.github/actions/setup", "./tool/.github/actions/setup", "./a/b/.github/actions/setup"] {
		count(double_star_messages([{"uses": path}])) == 0
	}
	double_star_messages([{"uses": "./.github/actions/setup-extra"}]) == {
		"job build is missing required action ./**/.github/actions/setup",
	}
}

test_a_longer_path_does_not_match if {
	messages([{"uses": "actions/checkout@v5"}, {"uses": "acme/tool/setup-extra@v1"}]) == {
		"job build is missing required action acme/tool/setup",
	}
}
