#!/usr/bin/env bash
# Request reviews for a PR
#
# This script:
# 1. Parses CODEOWNERS file (if configured)
# 2. Filters to configured maxReviewers limit
# 3. Requests reviews using gh CLI
# 4. Marks PR as ready for review

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}"

# Configuration
MAX_REVIEWERS="${FORK_JOIN_MAX_REVIEWERS:-3}"
USE_CODEOWNERS="${FORK_JOIN_USE_CODEOWNERS:-true}"
DEFAULT_REVIEWERS="${FORK_JOIN_DEFAULT_REVIEWERS:-}"

# Arguments
SESSION_ID="${1:-}"
PR_NUMBER="${2:-}"

# Parse CODEOWNERS file
get_codeowners() {
	local codeowners_file=""

	# Check common locations
	for path in ".github/CODEOWNERS" "CODEOWNERS" "docs/CODEOWNERS"; do
		if [[ -f "$path" ]]; then
			codeowners_file="$path"
			break
		fi
	done

	if [[ -z "$codeowners_file" ]]; then
		return
	fi

	# Parse owners (simplified - just get unique usernames/teams)
	grep -v '^#' "$codeowners_file" |
		grep -oE '@[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)?' |
		sort -u |
		head -n "$MAX_REVIEWERS"
}

main() {
	if [[ -z "$SESSION_ID" ]]; then
		# Try to get current session
		if [[ -f "${STATE_DIR}/current_session" ]]; then
			SESSION_ID="$(cat "${STATE_DIR}/current_session")"
		fi
	fi

	# Get PR number from session if not provided
	if [[ -z "$PR_NUMBER" && -n "$SESSION_ID" ]]; then
		local session_file="${STATE_DIR}/${SESSION_ID}.json"
		if [[ -f "$session_file" ]]; then
			PR_NUMBER="$(jq -r '.pr_number // empty' "$session_file")"
		fi
	fi

	if [[ -z "$PR_NUMBER" ]]; then
		echo "PR number is required" >&2
		exit 1
	fi

	echo "Requesting reviews for PR #${PR_NUMBER}..."

	# Collect reviewers
	local reviewers=()

	# Use default reviewers if configured
	if [[ -n "$DEFAULT_REVIEWERS" ]]; then
		IFS=',' read -ra reviewers <<<"$DEFAULT_REVIEWERS"
	# Otherwise try CODEOWNERS
	elif [[ "$USE_CODEOWNERS" == "true" ]]; then
		mapfile -t reviewers < <(get_codeowners)
	fi

	# Limit to max reviewers
	reviewers=("${reviewers[@]:0:$MAX_REVIEWERS}")

	if [[ ${#reviewers[@]} -eq 0 ]]; then
		echo "No reviewers found to request"
		cat <<EOF
{
    "reviews_requested": false,
    "reason": "no_reviewers_found",
    "pr_number": ${PR_NUMBER}
}
EOF
		exit 0
	fi

	# Clean up reviewer names (remove @ prefix if present)
	local clean_reviewers=()
	for reviewer in "${reviewers[@]}"; do
		clean_reviewers+=("${reviewer#@}")
	done

	echo "Requesting reviews from: ${clean_reviewers[*]}"

	# Request reviews
	local reviewer_args=""
	for reviewer in "${clean_reviewers[@]}"; do
		reviewer_args+=" --add-reviewer $reviewer"
	done

	# Mark PR as ready and add reviewers
	gh pr ready "$PR_NUMBER" 2>/dev/null || true
	eval "gh pr edit $PR_NUMBER $reviewer_args" 2>/dev/null || true

	# Update session state
	if [[ -n "$SESSION_ID" ]]; then
		local session_file="${STATE_DIR}/${SESSION_ID}.json"
		if [[ -f "$session_file" ]]; then
			local reviewers_json
			reviewers_json="$(printf '%s\n' "${clean_reviewers[@]}" | jq -R . | jq -s .)"

			jq --argjson reviewers "$reviewers_json" \
				'.reviewers_requested = $reviewers | .state = "READY_FOR_REVIEW"' \
				"$session_file" >"${session_file}.tmp" && mv "${session_file}.tmp" "$session_file"
		fi
	fi

	# Output result
	cat <<EOF
{
    "reviews_requested": true,
    "pr_number": ${PR_NUMBER},
    "reviewers": $(printf '%s\n' "${clean_reviewers[@]}" | jq -R . | jq -s .),
    "pr_ready": true
}
EOF
}

main "$@"
