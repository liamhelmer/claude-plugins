#!/usr/bin/env bash
# Run validation suite on the current branch
#
# This script runs:
# - Tests (configurable command)
# - Linting (configurable command)
# - Type checking (configurable command)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}"

# Default commands (can be overridden via config)
TEST_COMMAND="${FORK_JOIN_TEST_COMMAND:-npm test}"
LINT_COMMAND="${FORK_JOIN_LINT_COMMAND:-npm run lint}"
TYPECHECK_COMMAND="${FORK_JOIN_TYPECHECK_COMMAND:-npm run typecheck}"

# Arguments
SESSION_ID="${1:-}"
FAIL_FAST="${2:-false}"

# Result tracking
declare -A RESULTS
OVERALL_PASS=true

run_step() {
	local name="$1"
	local command="$2"

	echo "Running $name..."
	local output
	local exit_code=0

	if output=$(eval "$command" 2>&1); then
		RESULTS["$name"]='{"pass":true,"output":""}'
		echo "✓ $name passed"
	else
		exit_code=$?
		RESULTS["$name"]='{"pass":false,"exit_code":'$exit_code',"output":'$(echo "$output" | jq -Rs .)'}'
		echo "✗ $name failed (exit code: $exit_code)"
		OVERALL_PASS=false

		if [[ "$FAIL_FAST" == "true" ]]; then
			return 1
		fi
	fi

	return 0
}

main() {
	if [[ -z "$SESSION_ID" ]]; then
		# Try to get current session
		if [[ -f "${STATE_DIR}/current_session" ]]; then
			SESSION_ID="$(cat "${STATE_DIR}/current_session")"
		fi
	fi

	echo "Starting validation suite..."
	echo "================================"

	# Run tests
	if [[ -n "$TEST_COMMAND" ]]; then
		run_step "tests" "$TEST_COMMAND" || true
	fi

	# Run linting
	if [[ -n "$LINT_COMMAND" ]]; then
		run_step "lint" "$LINT_COMMAND" || true
	fi

	# Run type checking
	if [[ -n "$TYPECHECK_COMMAND" ]]; then
		run_step "typecheck" "$TYPECHECK_COMMAND" || true
	fi

	echo "================================"

	# Build results JSON
	local results_json="{"
	local first=true
	for key in "${!RESULTS[@]}"; do
		if [[ "$first" == "true" ]]; then
			first=false
		else
			results_json+=","
		fi
		results_json+="\"$key\":${RESULTS[$key]}"
	done
	results_json+="}"

	# Update session state if we have a session
	if [[ -n "$SESSION_ID" ]]; then
		local session_file="${STATE_DIR}/${SESSION_ID}.json"
		if [[ -f "$session_file" ]]; then
			local new_state
			if [[ "$OVERALL_PASS" == "true" ]]; then
				new_state="VALIDATED"
			else
				new_state="VALIDATION_FAILED"
			fi

			jq --argjson results "$results_json" --arg state "$new_state" \
				'.validation_results = $results | .state = $state' \
				"$session_file" >"${session_file}.tmp" && mv "${session_file}.tmp" "$session_file"
		fi
	fi

	# Output result
	if [[ "$OVERALL_PASS" == "true" ]]; then
		echo "All validations passed!"
		cat <<EOF
{
    "validation_passed": true,
    "results": $results_json
}
EOF
		exit 0
	else
		echo "Some validations failed!"
		cat <<EOF
{
    "validation_passed": false,
    "results": $results_json
}
EOF
		exit 1
	fi
}

main "$@"
