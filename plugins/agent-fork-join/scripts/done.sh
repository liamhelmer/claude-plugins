#!/usr/bin/env bash
# /done command - Complete local branch workflow
#
# SIMPLIFIED VERSION - Uses caching to avoid GitHub API calls
#
# This script (LOCAL ONLY):
# 1. Checks if current PR was merged (from cache)
# 2. Switches to main branch
# 3. Pulls latest changes
# 4. Deletes local feature branch (if PR merged)
# 5. Signals to run /compact

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "${SCRIPT_DIR}/../hooks/lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/../hooks/lib/git-utils.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/../hooks/lib/cache.sh" 2>/dev/null || true

DEBUG_LOG="/tmp/fork-join-done-debug.log"
debug_log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DONE] $*" >>"${DEBUG_LOG}"
}

output() {
	echo "$*"
}

# Track state
SHOULD_DELETE_LOCAL_BRANCH=""
CURRENT_JIRA_KEY=""
JIRA_URL=""
CURRENT_BEADS_ISSUE=""

# Load cached issue info
load_issue_info() {
	if issue_id=$(cache_get_issue_id 2>/dev/null); then
		CURRENT_BEADS_ISSUE="$issue_id"
		CURRENT_JIRA_KEY=$(cache_get_jira_key 2>/dev/null || echo "")
		JIRA_URL=$(cache_get_jira_url 2>/dev/null || echo "")
		debug_log "Issue: $CURRENT_BEADS_ISSUE ($CURRENT_JIRA_KEY)"
	fi
}

# Check if branch is a feature branch
is_feature_branch() {
	local branch="$1"
	[[ "$branch" =~ ^(build|ci|docs|feat|fix|perf|refactor|test)/ ]]
}

# Check PR status using cache
check_pr_status() {
	local current_branch="$1"

	if ! is_feature_branch "$current_branch"; then
		debug_log "Not a feature branch"
		return 0
	fi

	# Force refresh PR cache to get latest status
	cache_refresh_pr "$current_branch"

	local pr_number
	pr_number=$(cache_get_pr_number "$current_branch" 2>/dev/null || echo "")

	if [[ -z "$pr_number" ]]; then
		debug_log "No PR found for branch"
		output "No PR found for branch: $current_branch"
		return 0
	fi

	local pr_state
	pr_state=$(cache_get_pr_state "$current_branch" 2>/dev/null || echo "UNKNOWN")

	case "$pr_state" in
	"OPEN")
		output "PR #${pr_number} is still open."
		output "Merge the PR on GitHub when ready, then run /done again."
		;;
	"MERGED")
		output "PR #${pr_number} was merged."
		SHOULD_DELETE_LOCAL_BRANCH="$current_branch"

		# Comment on beads issue
		if [[ -n "$CURRENT_BEADS_ISSUE" ]]; then
			local comment="Pull request #${pr_number} merged.

---
_Automated comment from agent-fork-join_"
			beads_add_comment "$CURRENT_BEADS_ISSUE" "$comment" 2>/dev/null || true
			output "Commented on issue about merge."
		fi
		;;
	"CLOSED")
		# Check if it was merged
		if cache_pr_was_merged "$current_branch" 2>/dev/null; then
			output "PR #${pr_number} was merged."
			SHOULD_DELETE_LOCAL_BRANCH="$current_branch"

			if [[ -n "$CURRENT_BEADS_ISSUE" ]]; then
				local comment="Pull request #${pr_number} merged.

---
_Automated comment from agent-fork-join_"
				beads_add_comment "$CURRENT_BEADS_ISSUE" "$comment" 2>/dev/null || true
			fi
		else
			output "PR #${pr_number} is closed (not merged)."
		fi
		;;
	*)
		output "PR #${pr_number} has unknown state: $pr_state"
		;;
	esac
}

# Delete local branch
delete_local_branch() {
	local branch="$1"
	local default_branch="$2"

	if [[ -z "$branch" || "$branch" == "$default_branch" ]]; then
		return 0
	fi

	if ! git show-ref --verify --quiet "refs/heads/$branch"; then
		debug_log "Branch doesn't exist locally"
		return 0
	fi

	output "Deleting local branch: $branch..."
	if git branch -D "$branch" 2>&1; then
		output "Deleted local branch: $branch"
	else
		output "Warning: Could not delete branch $branch"
	fi

	# Clean remote tracking
	git branch -dr "origin/$branch" 2>/dev/null || true
}

# Switch to default branch
switch_to_default_branch() {
	local default_branch="$1"
	local current
	current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

	if [[ "$current" == "$default_branch" ]]; then
		output "Already on $default_branch branch."
		return 0
	fi

	output "Switching to $default_branch branch..."

	# Stash uncommitted changes
	if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
		output "Stashing uncommitted changes..."
		git stash push -m "Auto-stash before /done command"
	fi

	if git checkout "$default_branch" 2>&1; then
		output "Switched to $default_branch"
	else
		output "Error: Failed to switch to $default_branch"
		return 1
	fi
}

# Pull latest changes
pull_latest() {
	local default_branch="$1"

	output "Pulling latest changes from origin/$default_branch..."

	git fetch origin "$default_branch" 2>/dev/null || true

	local pull_output
	if pull_output=$(git pull origin "$default_branch" 2>&1); then
		if [[ "$pull_output" == *"Already up to date"* ]]; then
			output "Already up to date."
		else
			output "Successfully pulled latest changes."
		fi
		return 0
	else
		output "Warning: Pull encountered issues:"
		echo "$pull_output"

		if [[ "$pull_output" == *"CONFLICT"* ]]; then
			output ""
			output "Merge conflicts detected. Attempting auto-resolution..."
			if git checkout --theirs . 2>/dev/null; then
				git add -A
				if git commit -m "Auto-resolved conflicts during /done" 2>/dev/null; then
					output "Conflicts resolved by accepting remote changes."
					return 0
				fi
			fi
			output "Could not auto-resolve. Please resolve manually."
			return 1
		fi
		return 1
	fi
}

# Cleanup session state
cleanup_session() {
	local STATE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}"

	rm -f "${STATE_DIR}/current_session"
	rm -f "${STATE_DIR}/tracked_files.txt"

	# Clear caches
	cache_clear_session
	cache_clear_pr
	debug_log "Cleaned up session state"
}

# Ask about JIRA status change
ask_jira_status() {
	if [[ -z "$CURRENT_JIRA_KEY" ]]; then
		return 0
	fi

	output ""
	output "=== JIRA Ticket Status ==="
	output ""
	output "Current JIRA ticket: $CURRENT_JIRA_KEY"
	if [[ -n "$JIRA_URL" ]]; then
		output "URL: $JIRA_URL"
	fi
	output ""
	output "JIRA_TICKET_STATUS_QUESTION=true"
	output "JIRA_TICKET_ID=$CURRENT_JIRA_KEY"
	output ""
	output "The Claude agent should use AskUserQuestion to ask:"
	output "  Question: 'Would you like to update the JIRA ticket status?'"
	output "  Options:"
	output "    - 'Done' - Mark the ticket as done (clears tracking)"
	output "    - 'In Review' - Mark as in review (keeps tracking)"
	output "    - 'No change' - Leave status unchanged"
	output ""
}

main() {
	debug_log "=== /done command started ==="

	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		output "Error: Not in a git repository"
		exit 1
	fi

	# Load issue info from cache
	load_issue_info

	# Cache git state
	cache_git_state

	local current_branch
	current_branch=$(cache_get_branch)
	debug_log "Current branch: $current_branch"

	local default_branch
	default_branch=$(cache_get_default_branch)
	debug_log "Default branch: $default_branch"

	output ""
	output "=== Completing Branch Workflow ==="
	output ""

	# Step 1: Check PR status
	check_pr_status "$current_branch"
	output ""

	# Step 2: Ask about JIRA status if PR was merged
	if [[ -n "$CURRENT_JIRA_KEY" && -n "$SHOULD_DELETE_LOCAL_BRANCH" ]]; then
		ask_jira_status
	fi

	# Step 3: Switch to default branch
	if ! switch_to_default_branch "$default_branch"; then
		output "Failed to switch to $default_branch"
		exit 1
	fi
	output ""

	# Step 4: Pull latest
	if ! pull_latest "$default_branch"; then
		output "Pull failed. Please resolve conflicts manually."
		exit 1
	fi
	output ""

	# Step 5: Delete local branch if marked
	if [[ -n "$SHOULD_DELETE_LOCAL_BRANCH" ]]; then
		delete_local_branch "$SHOULD_DELETE_LOCAL_BRANCH" "$default_branch"
		output ""
	fi

	# Step 6: Cleanup
	cleanup_session

	output ""
	output "=== Workflow Complete ==="
	output ""
	output "Run /compact to consolidate conversation history."
	output ""

	echo "RUN_COMPACT=true"

	debug_log "=== /done command completed ==="
}

main "$@"
