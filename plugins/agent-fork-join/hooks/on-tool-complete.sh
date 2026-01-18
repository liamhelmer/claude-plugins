#!/usr/bin/env bash
# PostToolUse Hook - Auto-commits after file writes
#
# This hook:
# 1. Detects when Write/Edit tools complete
# 2. Automatically stages and commits the changed file
# 3. Uses Angular-style commit messages based on file path
#
# This enables the 5-commit minimum requirement without
# mentioning git in the prompt.

set -euo pipefail

# Debug logging
DEBUG_LOG="/tmp/fork-join-hook-debug.log"
debug_log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POST_TOOL] $*" >>"${DEBUG_LOG}"
}

debug_log "=== PostToolUse hook started ==="

# Guard against recursive hook calls
if [[ "${FORK_JOIN_HOOK_CONTEXT:-}" == "1" ]]; then
	debug_log "Already in hook context, skipping to prevent recursion"
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
	source "${SCRIPT_DIR}/lib/common.sh"
else
	exit 0
fi

if [[ -f "${SCRIPT_DIR}/lib/git-utils.sh" ]]; then
	source "${SCRIPT_DIR}/lib/git-utils.sh"
else
	exit 0
fi

# Read the input from stdin or argument
RAW_INPUT="${1:-}"
if [[ -z "$RAW_INPUT" ]] && [[ ! -t 0 ]]; then
	RAW_INPUT="$(cat)"
fi

debug_log "Raw input: ${RAW_INPUT:0:200}..."

# Extract tool name and file path from JSON input
TOOL_NAME=""
FILE_PATH=""

if command -v jq >/dev/null 2>&1; then
	TOOL_NAME=$(echo "$RAW_INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null || echo "")
	# Try different JSON structures for file path
	FILE_PATH=$(echo "$RAW_INPUT" | jq -r '.tool_input.file_path // .file_path // .path // empty' 2>/dev/null || echo "")
fi

debug_log "Tool: $TOOL_NAME, File: $FILE_PATH"

# Only process Write and Edit tools
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "MultiEdit" ]]; then
	debug_log "Not a file write tool ($TOOL_NAME), skipping"
	exit 0
fi

# Ensure we have a file path
if [[ -z "$FILE_PATH" ]]; then
	debug_log "No file path found, skipping"
	exit 0
fi

# Ensure we're in a git repository
if ! git_is_repo; then
	debug_log "Not in a git repository, skipping"
	exit 0
fi

# Get current branch
current_branch="$(git_current_branch)"
debug_log "Current branch: $current_branch"

# Skip if on main branch
if git_is_main_branch "$current_branch"; then
	debug_log "On main branch, skipping auto-commit"
	exit 0
fi

# Check if the file exists and has changes
if [[ ! -f "$FILE_PATH" ]]; then
	debug_log "File does not exist: $FILE_PATH"
	exit 0
fi

# Check if file has changes (staged or unstaged)
if ! git status --porcelain "$FILE_PATH" 2>/dev/null | grep -q .; then
	debug_log "No changes to file: $FILE_PATH"
	exit 0
fi

debug_log "File has changes, preparing to commit"

# Determine commit type and scope from file path
get_commit_info() {
	local file="$1"
	local type="feat"
	local scope=""

	# Extract scope from path (e.g., src/auth/index.ts -> auth)
	if [[ "$file" == src/* ]]; then
		scope=$(echo "$file" | cut -d'/' -f2)
	elif [[ "$file" == test/* || "$file" == tests/* || "$file" == *_test.* || "$file" == *.test.* ]]; then
		type="test"
		scope=$(basename "$(dirname "$file")")
	elif [[ "$file" == *.md ]]; then
		type="docs"
	elif [[ "$file" == .github/* ]]; then
		type="ci"
	fi

	echo "$type|$scope"
}

commit_info=$(get_commit_info "$FILE_PATH")
commit_type=$(echo "$commit_info" | cut -d'|' -f1)
commit_scope=$(echo "$commit_info" | cut -d'|' -f2)

# Generate commit message
filename=$(basename "$FILE_PATH")
if [[ -n "$commit_scope" && "$commit_scope" != "." ]]; then
	commit_msg="${commit_type}(${commit_scope}): add ${filename}"
else
	commit_msg="${commit_type}: add ${filename}"
fi

debug_log "Commit message: $commit_msg"

# Stage and commit the file
git add "$FILE_PATH" 2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
	debug_log "No staged changes after git add"
	exit 0
fi

if git commit -m "$commit_msg" 2>&1; then
	debug_log "Commit successful"
	echo "Auto-committed: $commit_msg"
else
	debug_log "Commit failed"
fi

debug_log "PostToolUse hook completed"
