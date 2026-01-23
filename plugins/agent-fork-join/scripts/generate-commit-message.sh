#!/usr/bin/env bash
# Generate Angular-style commit message WITHOUT LLM
# Usage: generate-commit-message.sh <branch-name> [changed-files] [session-prompt] [jira-key]
#
# Outputs commit message to stdout

set -euo pipefail

BRANCH_NAME="${1:-}"
CHANGED_FILES="${2:-}"
SESSION_PROMPT="${3:-}"
JIRA_KEY="${4:-}"

if [[ -z "$BRANCH_NAME" ]]; then
	echo "Usage: generate-commit-message.sh <branch-name> [changed-files] [session-prompt] [jira-key]" >&2
	exit 1
fi

# Valid Angular commit types
VALID_TYPES=("build" "ci" "docs" "feat" "fix" "perf" "refactor" "test")

# Extract commit type from branch name (e.g., "feat/add-auth" -> "feat")
get_commit_type() {
	local branch="$1"
	for type in "${VALID_TYPES[@]}"; do
		if [[ "$branch" == "${type}/"* ]]; then
			echo "$type"
			return 0
		fi
	done
	echo "feat"
}

# Extract description from branch name (e.g., "feat/add-auth" -> "add auth")
get_branch_description() {
	local branch="$1"
	echo "$branch" | sed 's/^[^/]*\///' | tr '-' ' '
}

# Determine scope from changed files
determine_scope() {
	local files="$1"

	if [[ -z "$files" ]]; then
		echo ""
		return
	fi

	# Get first file's directory structure
	local first_file
	first_file=$(echo "$files" | head -1)

	local first_dir
	first_dir=$(echo "$first_file" | cut -d'/' -f1)

	if [[ "$first_dir" == "src" ]]; then
		# Use second-level directory as scope
		local second_dir
		second_dir=$(echo "$first_file" | cut -d'/' -f2)
		if [[ -n "$second_dir" && "$second_dir" != "$first_file" ]]; then
			echo "$second_dir"
			return
		fi
	elif [[ "$first_dir" == "tests" || "$first_dir" == "test" ]]; then
		echo "test"
		return
	elif [[ "$first_dir" == "docs" ]]; then
		echo "docs"
		return
	elif [[ -n "$first_dir" && "$first_dir" != "." && "$first_dir" != ".." ]]; then
		# Use first directory as scope if it's reasonable
		if [[ ${#first_dir} -lt 20 ]]; then
			echo "$first_dir"
			return
		fi
	fi

	echo ""
}

# Build commit message header
build_header() {
	local commit_type="$1"
	local scope="$2"
	local description="$3"

	local header
	if [[ -n "$scope" ]]; then
		header="${commit_type}(${scope}): ${description}"
	else
		header="${commit_type}: ${description}"
	fi

	# Truncate if too long (max 72 chars)
	if [[ ${#header} -gt 72 ]]; then
		header="${header:0:69}..."
	fi

	echo "$header"
}

# Build commit message body
build_body() {
	local files="$1"
	local prompt="$2"

	local body=""

	# Add summary from prompt if available
	if [[ -n "$prompt" ]]; then
		# Take first 200 chars of prompt as context
		local prompt_summary="${prompt:0:200}"
		if [[ ${#prompt} -gt 200 ]]; then
			prompt_summary="${prompt_summary}..."
		fi
		body="Session work based on:
${prompt_summary}"
	fi

	# Add files changed if not too many
	if [[ -n "$files" ]]; then
		local file_count
		file_count=$(echo "$files" | wc -l | tr -d ' ')
		if [[ $file_count -le 10 ]]; then
			if [[ -n "$body" ]]; then
				body="${body}

"
			fi
			body="${body}Files changed:
$(echo "$files" | sed 's/^/- /')"
		else
			if [[ -n "$body" ]]; then
				body="${body}

"
			fi
			body="${body}Changed ${file_count} files"
		fi
	fi

	echo "$body"
}

# Main logic
main() {
	local commit_type
	commit_type=$(get_commit_type "$BRANCH_NAME")

	local description
	description=$(get_branch_description "$BRANCH_NAME")

	local scope
	scope=$(determine_scope "$CHANGED_FILES")

	local header
	header=$(build_header "$commit_type" "$scope" "$description")

	# Prepend JIRA key if provided
	if [[ -n "$JIRA_KEY" ]]; then
		header="${JIRA_KEY}: ${header}"
	fi

	local body
	body=$(build_body "$CHANGED_FILES" "$SESSION_PROMPT")

	# Output the commit message
	if [[ -n "$body" ]]; then
		echo "${header}

${body}"
	else
		echo "$header"
	fi
}

main
