#!/usr/bin/env bash
# AgentSpawn Hook - Triggered when an agent is spawned
#
# This hook:
# 1. Generates a unique agent ID
# 2. Creates an isolated git worktree for the agent
# 3. Registers the agent with the merge daemon
# 4. Updates session state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/git-utils.sh"
source "${SCRIPT_DIR}/lib/daemon-client.sh"

# Configuration
STATE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}"
WORKTREE_DIR="${FORK_JOIN_WORKTREE_DIR:-.worktrees}"
DAEMON_SOCKET="${FORK_JOIN_DAEMON_SOCKET:-/tmp/merge-daemon.sock}"
AGENT_BRANCH_PREFIX="${FORK_JOIN_AGENT_PREFIX:-agent/}"

# Read agent info from stdin or arguments
AGENT_TYPE="${1:-worker}"
AGENT_TASK="${2:-}"

main() {
	log_info "AgentSpawn hook triggered"

	# Get current session
	local session_id
	session_id="$(get_current_session)"

	if [[ -z "$session_id" ]]; then
		log_error "No active fork-join session"
		exit 1
	fi

	# Load session state
	local session_file="${STATE_DIR}/${session_id}.json"
	if [[ ! -f "$session_file" ]]; then
		log_error "Session file not found: $session_file"
		exit 1
	fi

	local feature_branch
	feature_branch="$(jq -r '.feature_branch' "$session_file")"

	# Generate unique agent ID
	local agent_id
	agent_id="agent-$(uuidgen | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')"

	log_info "Creating worktree for agent: $agent_id"

	# Create worktree directory
	mkdir -p "$WORKTREE_DIR"

	local worktree_path="${WORKTREE_DIR}/${agent_id}"
	local agent_branch="${AGENT_BRANCH_PREFIX}${session_id}/${agent_id}"

	# Create the worktree with a new branch
	git worktree add -b "$agent_branch" "$worktree_path" "$feature_branch"

	log_info "Created worktree at: $worktree_path"
	log_info "Agent branch: $agent_branch"

	# Register with daemon
	local register_result
	register_result="$(daemon_send '{"type":"REGISTER","agent_id":"'"$agent_id"'"}')"

	if [[ "$(echo "$register_result" | jq -r '.status // "ERROR"')" != "OK" ]]; then
		log_error "Failed to register agent with daemon: $register_result"
		# Cleanup worktree on failure
		git worktree remove "$worktree_path" --force 2>/dev/null || true
		git branch -D "$agent_branch" 2>/dev/null || true
		exit 1
	fi

	# Update session state with new agent
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	local agent_entry
	agent_entry=$(
		cat <<EOF
{
    "agent_id": "$agent_id",
    "agent_type": "$AGENT_TYPE",
    "worktree": "$worktree_path",
    "branch": "$agent_branch",
    "task": $(echo "$AGENT_TASK" | jq -Rs .),
    "status": "WORKING",
    "spawned_at": "$timestamp",
    "commit_message": null,
    "merged_at": null,
    "conflict_count": 0
}
EOF
	)

	# Add agent to session state
	local updated_state
	updated_state="$(jq --argjson agent "$agent_entry" '.agents += [$agent] | .state = "WORKING"' "$session_file")"
	echo "$updated_state" >"$session_file"

	# Output agent info for Claude Code
	cat <<EOF
{
    "agent_spawned": true,
    "agent_id": "${agent_id}",
    "worktree": "${worktree_path}",
    "branch": "${agent_branch}",
    "session_id": "${session_id}",
    "working_directory": "$(cd "$worktree_path" && pwd)"
}
EOF

	log_info "Agent $agent_id spawned successfully"
}

# Get current session ID
get_current_session() {
	local session_file="${STATE_DIR}/current_session"
	if [[ -f "$session_file" ]]; then
		cat "$session_file"
	fi
}

main "$@"
