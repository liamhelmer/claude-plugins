#!/usr/bin/env bash
# UserPromptSubmit Hook - Creates feature branch on new prompts
#
# Uses AI by default for branch name generation.
# Set FORK_JOIN_NO_AI=1 to disable AI and use heuristics only.
#
# This hook:
# 1. Checks if on GitHub repo on main/plugin branch
# 2. Creates feature branch using AI (with heuristic fallback)
# 3. Caches session state for other hooks

set -euo pipefail

# Debug logging
DEBUG_LOG="/tmp/fork-join-hook-debug.log"
debug_log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"${DEBUG_LOG}"
}

debug_log "=== UserPromptSubmit hook started ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
	debug_log "ERROR: common.sh not found"
	exit 1
}
source "${SCRIPT_DIR}/lib/git-utils.sh" 2>/dev/null || {
	debug_log "ERROR: git-utils.sh not found"
	exit 1
}
source "${SCRIPT_DIR}/lib/cache.sh" 2>/dev/null || {
	debug_log "ERROR: cache.sh not found"
	exit 1
}

# Guard against recursive hook calls
if [[ "${FORK_JOIN_HOOK_CONTEXT:-}" == "1" ]]; then
	debug_log "Already in hook context, skipping"
	exit 0
fi

# Read input (JSON with "prompt" field)
RAW_INPUT="${1:-}"
if [[ -z "$RAW_INPUT" ]] && [[ ! -t 0 ]]; then
	RAW_INPUT="$(cat)"
fi

# Extract prompt from JSON
PROMPT=""
if command -v jq >/dev/null 2>&1; then
	PROMPT=$(echo "$RAW_INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")
fi
if [[ -z "$PROMPT" ]]; then
	if [[ "$RAW_INPUT" != "{"* ]]; then
		PROMPT="$RAW_INPUT"
	fi
fi

if [[ -z "$PROMPT" ]]; then
	debug_log "ERROR: No prompt found"
	exit 1
fi

debug_log "Prompt: ${PROMPT:0:100}..."

# Keywords that indicate code changes
CHANGE_KEYWORDS=(
	"implement" "add" "create" "fix" "update" "modify" "refactor"
	"remove" "delete" "change" "write" "build" "develop" "spawn"
	"test" "optimize" "improve" "document" "configure" "setup"
)

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

# Append prompt to existing PR
append_prompt_to_pr() {
	local pr_number="$1"
	local new_prompt="$2"

	debug_log "Appending prompt to PR #${pr_number}"

	local current_body
	current_body=$(cache_get_pr_body)

	if [[ -z "$current_body" ]]; then
		debug_log "Could not get PR body"
		return 1
	fi

	local prompt_timestamp
	prompt_timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

	local new_prompt_section="
<details>
<summary>📝 Prompt - ${prompt_timestamp}</summary>

\`\`\`
${new_prompt}
\`\`\`

</details>"

	local updated_body
	if [[ "$current_body" == *"## Prompt History"* ]]; then
		updated_body="${current_body}
${new_prompt_section}"
	else
		updated_body="${current_body}

---

## Prompt History
${new_prompt_section}"
	fi

	if gh pr edit "$pr_number" --body "$updated_body" 2>/dev/null; then
		# Refresh cache with new body
		cache_refresh_pr
		log_info "Appended new prompt to PR #${pr_number}"
		return 0
	fi
	return 1
}

main() {
	log_info "UserPromptSubmit hook triggered"

	# Check if we're in a git repo
	if ! git_is_repo; then
		debug_log "Not in git repository"
		exit 0
	fi

	# Use cached git state
	cache_git_state

	if ! cache_is_github; then
		debug_log "Not a GitHub repository"
		exit 0
	fi

	# Handle beads/JIRA issue tracking
	local current_issue=""
	local jira_key=""
	local issue_status=""

	if current_issue=$(cache_get_issue_id 2>/dev/null); then
		jira_key=$(cache_get_jira_key 2>/dev/null || echo "")
		issue_status=$(cache_get_issue_status 2>/dev/null || echo "open")
		debug_log "Issue: $current_issue ($jira_key) status=$issue_status"

		# Update to in_progress if not already
		if [[ "$issue_status" != "in_progress" && "$issue_status" != "closed" ]]; then
			log_info "Setting $jira_key to In Progress..."
			if beads_update_status "$current_issue" "in_progress" 2>/dev/null; then
				cache_update_issue_status "in_progress"
				echo "Set $jira_key to In Progress"
			fi
		fi

		# Check if closed
		if [[ "$issue_status" == "closed" ]]; then
			debug_log "Issue $current_issue is closed"
			beads_clear_current_issue
			cache_clear_issue
			echo ""
			echo "=== Issue Completed ==="
			echo "BEADS_ISSUE_CLOSED=true"
			echo "BEADS_COMPLETED_ISSUE=$current_issue"
			echo "JIRA_COMPLETED_TICKET=$jira_key"
			echo ""
		fi
	fi

	# Check if plugin should activate
	if ! cache_is_github; then
		exit 0
	fi

	local on_main
	on_main=$(cache_is_main_branch && echo "true" || echo "false")
	local on_plugin_branch
	on_plugin_branch=$(cache_is_plugin_branch && echo "true" || echo "false")

	if [[ "$on_main" != "true" && "$on_plugin_branch" != "true" ]]; then
		debug_log "Not on main or plugin branch"
		exit 0
	fi

	# Check if prompt will make changes
	if ! prompt_will_make_changes; then
		debug_log "Prompt does not appear to make changes"
		exit 0
	fi

	log_info "Detected change-making prompt"

	local current_branch
	current_branch=$(cache_get_branch)
	local STATE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}"

	if [[ "$on_main" == "true" ]]; then
		log_info "On main branch, creating feature branch"

		# Generate branch name - try AI first unless disabled
		local feature_branch=""

		if [[ "${FORK_JOIN_NO_AI:-}" != "1" ]]; then
			# Try AI-generated branch name first
			local ai_branch
			if ai_branch=$("${SCRIPT_DIR}/../scripts/llm-enhance.sh" branch-name "$PROMPT" 10 2>/dev/null); then
				if [[ -n "$ai_branch" ]]; then
					feature_branch="$ai_branch"
					debug_log "Using AI-generated branch name: $feature_branch"
				fi
			fi
		fi

		# Fallback to heuristics if AI disabled or failed
		if [[ -z "$feature_branch" ]]; then
			feature_branch=$("${SCRIPT_DIR}/../scripts/generate-branch-name.sh" "$PROMPT" 2>/dev/null)
			debug_log "Using heuristic branch name: $feature_branch"
		fi

		debug_log "Branch name: $feature_branch"

		# Create and checkout branch
		if git checkout -b "$feature_branch" 2>&1; then
			log_info "Created feature branch: $feature_branch"
		else
			log_error "Failed to create branch"
			exit 1
		fi

		# Push branch immediately
		log_info "Pushing feature branch to origin..."
		if git push -u origin "$feature_branch" 2>&1; then
			log_info "Feature branch pushed successfully"
		else
			log_warn "Failed to push (may not have remote)"
		fi

		# Create session state
		local session_id
		session_id=$(cache_session_start "$feature_branch" "$PROMPT")

		# Create .fork-join directory state (for backwards compatibility)
		mkdir -p "$STATE_DIR"
		ensure_fork_join_gitignored
		echo "$session_id" >"${STATE_DIR}/current_session"

		# Refresh git cache with new branch
		cache_git_state

		echo "Feature branch '$feature_branch' created and pushed to origin."
		echo "Session ID: $session_id"
	else
		debug_log "On feature branch: $current_branch"

		# Check for existing PR
		local existing_pr
		existing_pr=$(cache_get_pr_number 2>/dev/null || echo "")

		if [[ -n "$existing_pr" ]]; then
			debug_log "Found existing PR #${existing_pr}"
			log_info "Existing PR #${existing_pr} found, appending prompt..."
			append_prompt_to_pr "$existing_pr" "$PROMPT"
			echo "Updated PR #${existing_pr} with new prompt"
		else
			echo "Already on feature branch: $current_branch"
		fi

		# Add prompt to session history
		cache_session_add_prompt "$PROMPT"
	fi

	debug_log "Hook completed"
	log_info "Fork-join hook completed"
}

main "$@"
