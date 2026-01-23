#!/usr/bin/env bash
# Generate PR summary/description WITHOUT LLM
# Usage: generate-pr-summary.sh <branch-name> [session-prompt] [commit-log] [jira-key] [jira-url]
#
# Outputs PR body markdown to stdout

set -euo pipefail

BRANCH_NAME="${1:-}"
SESSION_PROMPT="${2:-}"
COMMIT_LOG="${3:-}"
JIRA_KEY="${4:-}"
JIRA_URL="${5:-}"

if [[ -z "$BRANCH_NAME" ]]; then
	echo "Usage: generate-pr-summary.sh <branch-name> [session-prompt] [commit-log] [jira-key] [jira-url]" >&2
	exit 1
fi

# Valid Angular commit types and their descriptions
get_type_description() {
	local commit_type="$1"
	case "$commit_type" in
	feat) echo "A new feature" ;;
	fix) echo "A bug fix" ;;
	refactor) echo "Code refactoring" ;;
	perf) echo "Performance improvement" ;;
	test) echo "Tests" ;;
	docs) echo "Documentation" ;;
	build) echo "Build system changes" ;;
	ci) echo "CI configuration" ;;
	*) echo "Changes" ;;
	esac
}

# Extract commit type from branch
get_commit_type() {
	local branch="$1"
	local type="${branch%%/*}"
	case "$type" in
	build | ci | docs | feat | fix | perf | refactor | test) echo "$type" ;;
	*) echo "feat" ;;
	esac
}

# Extract description from branch name
get_branch_description() {
	local branch="$1"
	echo "$branch" | sed 's/^[^/]*\///' | tr '-' ' '
}

# Build summary section
build_summary_section() {
	local prompt="$1"
	local branch_desc="$2"

	echo "## Summary"
	echo ""

	if [[ -n "$prompt" ]]; then
		# Take first line or first 200 chars as summary
		local first_line
		first_line=$(echo "$prompt" | head -1 | sed 's/[[:space:]]*$//')
		if [[ ${#first_line} -gt 200 ]]; then
			first_line="${first_line:0:197}..."
		fi
		echo "$first_line"
	else
		echo "This PR implements: $branch_desc"
	fi
	echo ""
}

# Build changes section from commit log
build_changes_section() {
	local commit_log="$1"

	if [[ -z "$commit_log" ]]; then
		return
	fi

	echo "## Changes Made"
	echo ""

	# Format each commit as a bullet point
	echo "$commit_log" | while read -r line; do
		if [[ -n "$line" ]]; then
			# Remove commit hash prefix if present
			local message
			message=$(echo "$line" | sed 's/^[a-f0-9]* //')
			echo "- $message"
		fi
	done
	echo ""
}

# Build why section
build_why_section() {
	local commit_type="$1"
	local type_desc="$2"

	echo "## Why"
	echo ""
	echo "This PR implements the requested changes as a ${type_desc} task."
	echo ""
}

# Build JIRA section if applicable
build_jira_section() {
	local jira_key="$1"
	local jira_url="$2"

	if [[ -z "$jira_key" ]]; then
		return
	fi

	local url_display="$jira_url"
	if [[ -z "$url_display" ]]; then
		url_display="#"
	fi

	echo "## JIRA Ticket"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Ticket | [\`${jira_key}\`](${url_display}) |"
	echo ""
}

# Build metadata section
build_metadata_section() {
	local commit_type="$1"
	local type_desc="$2"
	local branch="$3"
	local commit_count="$4"

	echo "---"
	echo ""
	echo "## Metadata"
	echo ""
	echo "| Field | Value |"
	echo "|-------|-------|"
	echo "| Type | \`${commit_type}\` - ${type_desc} |"
	echo "| Branch | \`${branch}\` |"
	echo "| Commits | ${commit_count} |"
	echo ""
}

# Build prompt history section
build_prompt_history_section() {
	local prompt="$1"
	local timestamp
	timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

	echo "---"
	echo ""
	echo "## Prompt History"
	echo ""
	echo "<details>"
	echo "<summary>📝 Prompt - ${timestamp}</summary>"
	echo ""
	echo '```'
	if [[ -n "$prompt" ]]; then
		echo "$prompt"
	else
		echo "No prompt recorded"
	fi
	echo '```'
	echo ""
	echo "</details>"
}

# Main logic
main() {
	local commit_type
	commit_type=$(get_commit_type "$BRANCH_NAME")

	local type_desc
	type_desc=$(get_type_description "$commit_type")

	local branch_desc
	branch_desc=$(get_branch_description "$BRANCH_NAME")

	local commit_count=0
	if [[ -n "$COMMIT_LOG" ]]; then
		commit_count=$(echo "$COMMIT_LOG" | wc -l | tr -d ' ')
	fi

	# Build the PR body
	build_summary_section "$SESSION_PROMPT" "$branch_desc"
	build_changes_section "$COMMIT_LOG"
	build_why_section "$commit_type" "$type_desc"
	build_jira_section "$JIRA_KEY" "$JIRA_URL"
	build_metadata_section "$commit_type" "$type_desc" "$BRANCH_NAME" "$commit_count"
	build_prompt_history_section "$SESSION_PROMPT"
}

main
