#!/usr/bin/env bash
# Stop Hook - Commits changes and creates PR when session completes
#
# Uses AI by default for commit messages and PR summaries.
# Set FORK_JOIN_NO_AI=1 to disable AI and use heuristics only.
#
# This hook:
# 1. Commits all tracked changes in a single commit (AI-generated message)
# 2. Pushes to remote
# 3. Creates PR with AI-generated summary if one doesn't exist

set -euo pipefail

DEBUG_LOG="/tmp/fork-join-hook-debug.log"
debug_log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STOP] $*" >>"${DEBUG_LOG}"
}

debug_log "=== Stop hook started ==="

# Guard against recursive calls
if [[ "${FORK_JOIN_HOOK_CONTEXT:-}" == "1" ]]; then
	debug_log "Already in hook context, skipping"
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/lib/git-utils.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/lib/cache.sh" 2>/dev/null || exit 0

# Get cached issue/JIRA info
CURRENT_BEADS_ISSUE=""
CURRENT_JIRA_KEY=""
JIRA_URL=""

if issue_id=$(cache_get_issue_id 2>/dev/null); then
	CURRENT_BEADS_ISSUE="$issue_id"
	CURRENT_JIRA_KEY=$(cache_get_jira_key 2>/dev/null || echo "")
	JIRA_URL=$(cache_get_jira_url 2>/dev/null || echo "")
	debug_log "Issue: $CURRENT_BEADS_ISSUE (JIRA: $CURRENT_JIRA_KEY)"
fi

main() {
	debug_log "main() called"

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

	local current_branch
	current_branch=$(cache_get_branch)
	debug_log "Current branch: $current_branch"

	# Skip if on main branch
	if cache_is_main_branch; then
		debug_log "On main branch, skipping"
		exit 0
	fi

	# Only proceed on plugin-created branches
	if ! cache_is_plugin_branch; then
		debug_log "Not on plugin branch, skipping"
		exit 0
	fi

	debug_log "On feature branch: $current_branch"

	# Get session info from cache
	local session_prompt
	session_prompt=$(cache_get_session_prompt 2>/dev/null || echo "")
	local STATE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}"

	# Check for uncommitted changes
	local changes
	changes=$(git status --porcelain)

	if [[ -n "$changes" ]]; then
		debug_log "Found uncommitted changes"

		local changed_files
		changed_files=$(git status --porcelain | awk '{print $2}')

		# Stage all changes
		git add -A

		# Generate commit message - try AI first unless disabled
		local commit_msg=""

		if [[ "${FORK_JOIN_NO_AI:-}" != "1" ]]; then
			export FORK_JOIN_HOOK_CONTEXT=1
			local ai_msg
			if ai_msg=$("${SCRIPT_DIR}/../scripts/llm-enhance.sh" commit \
				"$changed_files" "$session_prompt" "$current_branch" 10 2>/dev/null); then
				if [[ -n "$ai_msg" ]]; then
					# Prepend JIRA key if needed
					if [[ -n "$CURRENT_JIRA_KEY" ]]; then
						commit_msg="${CURRENT_JIRA_KEY}: ${ai_msg}"
					else
						commit_msg="$ai_msg"
					fi
					debug_log "Using AI-generated commit message"
				fi
			fi
			unset FORK_JOIN_HOOK_CONTEXT
		fi

		# Fallback to heuristics if AI disabled or failed
		if [[ -z "$commit_msg" ]]; then
			commit_msg=$("${SCRIPT_DIR}/../scripts/generate-commit-message.sh" \
				"$current_branch" \
				"$changed_files" \
				"$session_prompt" \
				"$CURRENT_JIRA_KEY" 2>/dev/null)
			debug_log "Using heuristic commit message"
		fi

		debug_log "Commit message: ${commit_msg:0:100}..."

		if git commit -m "$commit_msg"; then
			debug_log "Commit successful"
		else
			debug_log "Commit failed"
		fi
	fi

	# Push changes
	debug_log "Pushing to origin"
	git push origin "$current_branch" 2>&1 || true

	# Check if PR exists (from cache)
	local existing_pr
	existing_pr=$(cache_get_pr_number 2>/dev/null || echo "")

	if [[ -n "$existing_pr" ]]; then
		debug_log "PR #${existing_pr} already exists"
		echo "Pull request #${existing_pr} already exists for branch $current_branch"
		exit 0
	fi

	# Extract commit type for PR title
	local commit_type="${current_branch%%/*}"
	local branch_desc
	branch_desc=$(echo "$current_branch" | sed 's/^[^/]*\///' | tr '-' ' ')

	# Build PR title
	local pr_title
	if [[ -n "$CURRENT_JIRA_KEY" ]]; then
		pr_title="${CURRENT_JIRA_KEY}: ${commit_type}: ${branch_desc}"
	else
		pr_title="${commit_type}: ${branch_desc}"
	fi
	if [[ ${#pr_title} -gt 72 ]]; then
		pr_title="${pr_title:0:69}..."
	fi

	# Get commit log for this branch
	local base_branch
	base_branch=$(cache_get_default_branch)
	local commit_log
	commit_log=$(git log --oneline "${base_branch}..HEAD" 2>/dev/null || git log --oneline -10 2>/dev/null || echo "")

	# Generate PR body - try AI first unless disabled
	local pr_body=""

	# First generate the heuristic body (we need the metadata sections)
	local heuristic_body
	heuristic_body=$("${SCRIPT_DIR}/../scripts/generate-pr-summary.sh" \
		"$current_branch" \
		"$session_prompt" \
		"$commit_log" \
		"$CURRENT_JIRA_KEY" \
		"$JIRA_URL" 2>/dev/null)

	if [[ "${FORK_JOIN_NO_AI:-}" != "1" && -n "$session_prompt" ]]; then
		export FORK_JOIN_HOOK_CONTEXT=1
		local ai_summary
		if ai_summary=$("${SCRIPT_DIR}/../scripts/llm-enhance.sh" pr-summary \
			"$session_prompt" "$commit_log" "$current_branch" 15 2>/dev/null); then
			if [[ -n "$ai_summary" ]]; then
				# Use AI summary but keep our structured metadata sections
				pr_body="${ai_summary}

---

$(echo "$heuristic_body" | sed -n '/^## JIRA Ticket/,$p')"
				debug_log "Using AI-generated PR summary"
			fi
		fi
		unset FORK_JOIN_HOOK_CONTEXT
	fi

	# Fallback to heuristics if AI disabled or failed
	if [[ -z "$pr_body" ]]; then
		pr_body="$heuristic_body"
		debug_log "Using heuristic PR summary"
	fi

	# Create PR
	debug_log "Creating pull request"
	local pr_url
	if pr_url=$(gh pr create --title "$pr_title" --body "$pr_body" --head "$current_branch" 2>&1); then
		debug_log "PR created successfully"
		echo "Pull request created for branch $current_branch"

		# Refresh PR cache
		cache_refresh_pr

		# Comment on beads issue
		if [[ -n "$CURRENT_BEADS_ISSUE" ]]; then
			debug_log "Commenting on beads issue"

			local actual_pr_url
			actual_pr_url=$(cache_get_pr_url 2>/dev/null || echo "$pr_url")

			local beads_comment="Pull request created for this issue:

**PR Title:** ${pr_title}
**PR URL:** ${actual_pr_url}
**JIRA Ticket:** ${CURRENT_JIRA_KEY:-N/A}

---
_Automated comment from agent-fork-join_"

			if beads_add_comment "$CURRENT_BEADS_ISSUE" "$beads_comment" 2>/dev/null; then
				echo "Commented on beads issue $CURRENT_BEADS_ISSUE"
			fi
		fi
	else
		debug_log "Failed to create PR"
	fi

	# Cleanup tracked files
	rm -f "${STATE_DIR}/tracked_files.txt"

	debug_log "Stop hook completed"
}

main "$@"
