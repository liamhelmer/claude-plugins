#!/usr/bin/env bash
# Optional LLM enhancement for commit messages and PR summaries
# This is called ONLY when --use-ai flag is passed
# Usage:
#   llm-enhance.sh branch-name <prompt> [timeout]     - Generate branch name
#   llm-enhance.sh commit <files> <prompt> <branch>   - Generate commit message
#   llm-enhance.sh pr-summary <prompt> <commits> <branch> - Generate PR summary
#   llm-enhance.sh analyze-pr <pr-body> <new-prompt>  - Analyze if PR needs update
#
# Returns enhanced text on stdout, or exit 1 if LLM not available/timeout

set -euo pipefail

MODE="${1:-}"
shift || true

# Check for claude CLI
if ! command -v claude >/dev/null 2>&1; then
	echo "ERROR: Claude CLI not available" >&2
	exit 1
fi

# Fast claude call with timeout
claude_fast_call() {
	local prompt="$1"
	local timeout_seconds="${2:-15}"

	# Speed optimization flags
	local claude_cmd="claude -p --model haiku --no-chrome --no-session-persistence"
	claude_cmd+=" --setting-sources '' --disable-slash-commands"
	claude_cmd+=" --strict-mcp-config --mcp-config ''"

	local result=""

	if command -v timeout >/dev/null 2>&1; then
		result=$(echo "$prompt" | timeout "$timeout_seconds" bash -c "$claude_cmd -p -" 2>/dev/null) || true
	elif command -v gtimeout >/dev/null 2>&1; then
		result=$(echo "$prompt" | gtimeout "$timeout_seconds" bash -c "$claude_cmd -p -" 2>/dev/null) || true
	else
		# Background process with sleep-based timeout
		local tmp_output
		tmp_output=$(mktemp)
		(echo "$prompt" | bash -c "$claude_cmd -p -" >"$tmp_output" 2>/dev/null) &
		local pid=$!
		local waited=0
		while kill -0 $pid 2>/dev/null && [[ $waited -lt $timeout_seconds ]]; do
			sleep 1
			((waited++))
		done
		if kill -0 $pid 2>/dev/null; then
			kill $pid 2>/dev/null || true
			wait $pid 2>/dev/null || true
		fi
		if [[ -f "$tmp_output" ]]; then
			result=$(cat "$tmp_output")
			rm -f "$tmp_output"
		fi
	fi

	if [[ -z "$result" ]]; then
		exit 1
	fi

	echo "$result"
}

# Generate branch name using AI
generate_branch_name() {
	local prompt_text="$1"
	local timeout="${2:-10}"

	# Sanitize prompt (first 500 chars)
	local sanitized_prompt
	sanitized_prompt=$(echo "$prompt_text" | tr '\n\r' ' ' | head -c 500)

	local ai_prompt="Analyze this task and generate a git branch name.

VALID TYPES: feat, fix, refactor, perf, test, docs, build, ci

FORMAT: <type>/<short-description>
- lowercase only
- hyphens between words
- max 40 chars in description
- use complete words only

TASK: ${sanitized_prompt}

OUTPUT ONLY THE BRANCH NAME (e.g., feat/add-user-auth):"

	local result
	result=$(claude_fast_call "$ai_prompt" "$timeout")

	# Extract branch name pattern from response
	local branch
	branch=$(echo "$result" | tr '\n\r\t' ' ' | grep -oE '(build|ci|docs|feat|fix|perf|refactor|test)/[a-z0-9-]+' | head -1)

	if [[ -n "$branch" ]]; then
		echo "$branch"
	else
		exit 1
	fi
}

# Generate commit message using AI
generate_commit_message() {
	local changed_files="$1"
	local session_prompt="$2"
	local branch_name="$3"
	local timeout="${4:-10}"

	# Get commit type from branch
	local commit_type="${branch_name%%/*}"

	local ai_prompt="Generate an Angular-style commit message for the following changes.

COMMIT MESSAGE FORMAT:
<type>(<scope>): <short summary>

<body>

RULES:
1. type: Must be \"$commit_type\"
2. scope: Optional, area of code affected
3. summary: Imperative mood, lowercase, no period, max 72 chars
4. body: Explain WHY the change was made

BRANCH NAME: $branch_name

ORIGINAL TASK:
$session_prompt

FILES CHANGED:
$changed_files

Generate ONLY the commit message, nothing else."

	claude_fast_call "$ai_prompt" "$timeout"
}

# Generate PR summary using AI
generate_pr_summary() {
	local original_prompt="$1"
	local commit_log="$2"
	local branch_name="$3"
	local timeout="${4:-15}"

	# Sanitize inputs
	local sanitized_prompt
	sanitized_prompt=$(echo "$original_prompt" | tr '\n' ' ' | head -c 1000)
	local sanitized_commits
	sanitized_commits=$(echo "$commit_log" | head -c 1500)

	local ai_prompt="Generate a PR description for the following work.

ORIGINAL TASK:
${sanitized_prompt}

COMMITS MADE:
${sanitized_commits}

BRANCH: ${branch_name}

Generate a PR description with these sections:
1. **Summary**: 2-3 sentences describing what was requested in plain English
2. **Changes Made**: Bullet list of what was implemented
3. **Why**: Brief explanation of why these changes were made

Keep it concise and professional. Output only the PR description."

	claude_fast_call "$ai_prompt" "$timeout"
}

# Analyze if PR needs updating with new prompt
analyze_pr_for_updates() {
	local current_body="$1"
	local new_prompt="$2"
	local timeout="${3:-15}"

	# Truncate inputs
	local sanitized_body
	sanitized_body=$(echo "$current_body" | head -c 2000)
	local sanitized_prompt
	sanitized_prompt=$(echo "$new_prompt" | tr '\n' ' ' | head -c 800)

	local ai_prompt="Analyze this PR description and determine if it needs updating based on the new prompt.

CURRENT PR DESCRIPTION:
${sanitized_body}

NEW PROMPT FROM USER:
${sanitized_prompt}

INSTRUCTIONS:
1. Compare the new prompt to what's already described in the PR
2. If the new prompt adds NEW functionality not covered, output suggested updates
3. If the new prompt is just continuation of existing work, output 'NO_UPDATE_NEEDED'

OUTPUT FORMAT:
- If updates needed: Output ONLY the text to ADD (bullet points starting with '- ')
- If no updates needed: Output exactly 'NO_UPDATE_NEEDED'

Be concise."

	claude_fast_call "$ai_prompt" "$timeout"
}

# Main dispatch
case "$MODE" in
branch-name)
	generate_branch_name "$@"
	;;
commit)
	generate_commit_message "$@"
	;;
pr-summary)
	generate_pr_summary "$@"
	;;
analyze-pr)
	analyze_pr_for_updates "$@"
	;;
*)
	echo "Usage: llm-enhance.sh <mode> [args...]" >&2
	echo "Modes: branch-name, commit, pr-summary, analyze-pr" >&2
	exit 1
	;;
esac
