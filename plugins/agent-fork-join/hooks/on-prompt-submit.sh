#!/usr/bin/env bash
# UserPromptSubmit Hook - Triggered when user submits a prompt
#
# This hook:
# 1. Analyzes the prompt to detect if it will make changes
# 2. Creates a feature branch if not already on one
# 3. Starts the merge daemon if not running
# 4. Initializes session state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/git-utils.sh"
source "${SCRIPT_DIR}/lib/daemon-client.sh"

# Configuration
STATE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}"
DAEMON_SOCKET="${FORK_JOIN_DAEMON_SOCKET:-/tmp/merge-daemon.sock}"
FEATURE_BRANCH_PREFIX="${FORK_JOIN_FEATURE_PREFIX:-feature/}"

# Read the prompt from stdin or argument
PROMPT="${1:-}"
if [[ -z "$PROMPT" ]] && [[ ! -t 0 ]]; then
	PROMPT="$(cat)"
fi

# Keywords that indicate the prompt will make changes
CHANGE_KEYWORDS=(
	"implement"
	"add"
	"create"
	"fix"
	"update"
	"modify"
	"refactor"
	"remove"
	"delete"
	"change"
	"write"
	"build"
	"develop"
	"migrate"
	"upgrade"
	"convert"
)

# Function to check if prompt indicates changes
prompt_will_make_changes() {
	local prompt_lower
	prompt_lower="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"

	for keyword in "${CHANGE_KEYWORDS[@]}"; do
		if [[ "$prompt_lower" == *"$keyword"* ]]; then
			return 0
		fi
	done

	return 1
}

# Function to generate a branch name from prompt
generate_branch_name() {
	local slug
	# Take first few words, lowercase, replace spaces with dashes
	slug=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | awk '{print $1"-"$2"-"$3}' | sed 's/-*$//')

	if [[ -z "$slug" ]]; then
		slug="task-$(date +%s)"
	fi

	echo "${FEATURE_BRANCH_PREFIX}${slug}"
}

# Function to create session state file
create_session_state() {
	local session_id="$1"
	local feature_branch="$2"
	local base_branch="$3"

	mkdir -p "$STATE_DIR"

	cat >"${STATE_DIR}/${session_id}.json" <<EOF
{
    "session_id": "${session_id}",
    "feature_branch": "${feature_branch}",
    "base_branch": "${base_branch}",
    "original_prompt": $(echo "$PROMPT" | jq -Rs .),
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "state": "STARTED",
    "agents": [],
    "merged_commits": [],
    "pr_number": null,
    "validation_results": null
}
EOF

	# Also store current session ID
	echo "$session_id" >"${STATE_DIR}/current_session"
}

main() {
	log_info "UserPromptSubmit hook triggered"

	# Check if prompt will make changes
	if ! prompt_will_make_changes; then
		log_debug "Prompt does not appear to make changes, skipping fork-join setup"
		exit 0
	fi

	log_info "Detected change-making prompt, initializing fork-join session"

	# Ensure we're in a git repository
	if ! git_is_repo; then
		log_error "Not in a git repository"
		exit 1
	fi

	# Get current branch
	local current_branch
	current_branch="$(git_current_branch)"

	# Check if we need to create a feature branch
	local feature_branch="$current_branch"
	local base_branch="$current_branch"

	if git_is_main_branch "$current_branch"; then
		log_info "Currently on main branch ($current_branch), creating feature branch"

		feature_branch="$(generate_branch_name)"
		base_branch="$current_branch"

		# Create and checkout feature branch
		git checkout -b "$feature_branch"
		log_info "Created feature branch: $feature_branch"
	else
		log_info "Already on feature branch: $feature_branch"
		# Try to determine base branch
		base_branch="$(git_find_base_branch)"
	fi

	# Generate session ID
	local session_id
	session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

	# Create session state
	create_session_state "$session_id" "$feature_branch" "$base_branch"
	log_info "Created session: $session_id"

	# Start merge daemon if not running
	if ! daemon_is_running; then
		log_info "Starting merge daemon..."
		start_daemon

		# Wait for daemon to be ready
		local retries=10
		while ! daemon_is_running && [[ $retries -gt 0 ]]; do
			sleep 0.5
			retries=$((retries - 1))
		done

		if ! daemon_is_running; then
			log_error "Failed to start merge daemon"
			exit 1
		fi

		log_info "Merge daemon started"
	else
		log_debug "Merge daemon already running"
	fi

	# Output session info for Claude Code to use
	cat <<EOF
{
    "fork_join_initialized": true,
    "session_id": "${session_id}",
    "feature_branch": "${feature_branch}",
    "base_branch": "${base_branch}",
    "daemon_socket": "${DAEMON_SOCKET}"
}
EOF

	log_info "Fork-join session initialized successfully"
}

main "$@"
