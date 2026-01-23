#!/usr/bin/env bash
# Generate Angular-style branch name from prompt WITHOUT LLM
# This is a fast heuristic-based approach that should work for 90% of cases
# Usage: generate-branch-name.sh "prompt text" [--ai-fallback]
#
# Exit codes:
#   0 - Branch name generated successfully
#   1 - No valid prompt provided
#
# Outputs branch name to stdout (e.g., "feat/add-user-auth")

set -euo pipefail

PROMPT="${1:-}"
USE_AI_FALLBACK="${2:-}"

if [[ -z "$PROMPT" ]]; then
	echo "Usage: generate-branch-name.sh 'prompt text' [--ai-fallback]" >&2
	exit 1
fi

# Valid Angular commit types
VALID_TYPES=("build" "ci" "docs" "feat" "fix" "perf" "refactor" "test")

# Sanitize a string for git branch name
sanitize_branch_name() {
	local input="$1"
	local max_length="${2:-50}"

	# Convert to single line, lowercase
	local sanitized
	sanitized=$(echo "$input" | tr '\n\r\t' ' ' | tr '[:upper:]' '[:lower:]')

	# Replace invalid chars with hyphens
	sanitized=$(echo "$sanitized" | sed 's/[^a-z0-9/_.-]/-/g')

	# Remove consecutive hyphens
	sanitized=$(echo "$sanitized" | sed 's/--*/-/g')

	# Remove leading/trailing hyphens
	sanitized=$(echo "$sanitized" | sed 's/^[-.]*//' | sed 's/[-.]*$//')

	# Truncate at word boundary
	if [[ ${#sanitized} -gt $max_length ]]; then
		sanitized="${sanitized:0:$max_length}"
		if [[ "$sanitized" == *-* ]]; then
			sanitized="${sanitized%-*}"
		fi
	fi

	# Remove trailing hyphen after truncation
	sanitized=$(echo "$sanitized" | sed 's/[-.]*$//')

	echo "$sanitized"
}

# Determine commit type from prompt keywords
determine_type() {
	local prompt_lower
	prompt_lower="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"

	# Check keywords in order of specificity
	if [[ "$prompt_lower" =~ (fix|bug|error|issue|broken|crash|fail|wrong) ]]; then
		echo "fix"
	elif [[ "$prompt_lower" =~ (test|spec|unit|integration|e2e|coverage) ]]; then
		echo "test"
	elif [[ "$prompt_lower" =~ (document|readme|doc|comment|jsdoc|explain) ]]; then
		echo "docs"
	elif [[ "$prompt_lower" =~ (refactor|restructure|reorganize|clean|simplify|move|rename|extract) ]]; then
		echo "refactor"
	elif [[ "$prompt_lower" =~ (performance|optimize|speed|faster|slow|cache|lazy|efficient) ]]; then
		echo "perf"
	elif [[ "$prompt_lower" =~ (build|dependency|package|npm|yarn|webpack|vite|bundle) ]]; then
		echo "build"
	elif [[ "$prompt_lower" =~ (ci|pipeline|workflow|github.action|deploy|release) ]]; then
		echo "ci"
	else
		echo "feat"
	fi
}

# Extract key descriptive words from prompt
extract_description() {
	local prompt_text="$1"

	# Common words to skip
	local skip_words="the a an to and or for in on with that this is are be will please can you i implement add create fix update modify refactor task using use tool must each make sure"

	# Convert to lowercase, single line
	local single_line
	single_line=$(echo "$prompt_text" | tr '\n\r\t' ' ' | head -c 200 | tr '[:upper:]' '[:lower:]')

	# Replace non-alphanumeric with spaces
	single_line=$(echo "$single_line" | sed 's/[^a-z0-9]/ /g')

	# Extract meaningful words (awk script to filter and limit)
	local description
	description=$(echo "$single_line" | awk -v skip="$skip_words" '
	BEGIN {
		n = split(skip, arr, " ")
		for (i = 1; i <= n; i++) skipword[arr[i]] = 1
	}
	{
		words = ""
		count = 0
		for (i = 1; i <= NF && count < 4; i++) {
			if (!($i in skipword) && length($i) > 2) {
				if (words != "") words = words "-"
				words = words $i
				count++
			}
		}
		print words
	}')

	# Sanitize the description
	description=$(sanitize_branch_name "$description" 40)

	# Fallback if empty
	if [[ -z "$description" || "$description" == "-" ]]; then
		description="task-$(date +%s | tail -c 6)"
	fi

	echo "$description"
}

# Check if user specified a branch name in the prompt
extract_user_branch() {
	local prompt_lower
	prompt_lower="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"

	# Look for explicit branch name patterns
	local branch_name=""

	# Pattern: "branch: <name>" or "branch name: <name>"
	if [[ "$prompt_lower" =~ branch[[:space:]]*name?[[:space:]]*:[[:space:]]*([a-z0-9/_-]+) ]]; then
		branch_name="${BASH_REMATCH[1]}"
	# Pattern: "on branch <name>"
	elif [[ "$prompt_lower" =~ on[[:space:]]+branch[[:space:]]+([a-z0-9/_-]+) ]]; then
		branch_name="${BASH_REMATCH[1]}"
	# Pattern: "use branch <name>"
	elif [[ "$prompt_lower" =~ use[[:space:]]+branch[[:space:]]+([a-z0-9/_-]+) ]]; then
		branch_name="${BASH_REMATCH[1]}"
	fi

	echo "$branch_name"
}

# Validate branch type prefix
validate_type() {
	local branch="$1"
	for type in "${VALID_TYPES[@]}"; do
		if [[ "$branch" == "${type}/"* ]]; then
			return 0
		fi
	done
	return 1
}

# Main logic
main() {
	local branch_name=""

	# First: check for user-specified branch name
	branch_name=$(extract_user_branch)
	if [[ -n "$branch_name" ]]; then
		if validate_type "$branch_name"; then
			echo "$branch_name"
			exit 0
		else
			# Add type prefix
			local commit_type
			commit_type=$(determine_type)
			echo "${commit_type}/${branch_name}"
			exit 0
		fi
	fi

	# Second: use heuristics
	local commit_type
	commit_type=$(determine_type)

	local description
	description=$(extract_description "$PROMPT")

	branch_name="${commit_type}/${description}"
	echo "$branch_name"
}

main
