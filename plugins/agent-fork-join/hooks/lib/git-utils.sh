#!/usr/bin/env bash
# Git utility functions for fork-join hooks

# Check if current directory is a git repository
git_is_repo() {
	git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Check if the repository has a GitHub remote
git_is_github_repo() {
	local remote_url
	remote_url=$(git remote get-url origin 2>/dev/null || echo "")

	if [[ -z "$remote_url" ]]; then
		return 1
	fi

	# Check if remote URL contains github.com
	if [[ "$remote_url" == *"github.com"* ]]; then
		return 0
	fi

	return 1
}

# Valid Angular commit type prefixes for plugin-created branches
PLUGIN_BRANCH_PREFIXES=("build" "ci" "docs" "feat" "fix" "perf" "refactor" "test")

# Check if current branch was created by the plugin (follows Angular convention)
git_is_plugin_branch() {
	local branch="${1:-$(git_current_branch)}"

	# Check if branch matches pattern: type/description
	for prefix in "${PLUGIN_BRANCH_PREFIXES[@]}"; do
		if [[ "$branch" == "${prefix}/"* ]]; then
			return 0
		fi
	done

	return 1
}

# Check if the plugin should activate for current repo/branch state
git_should_plugin_activate() {
	# Must be a GitHub repository
	if ! git_is_github_repo; then
		return 1
	fi

	local current_branch
	current_branch="$(git_current_branch)"

	# Activate if on default branch (main/master)
	if git_is_main_branch "$current_branch"; then
		return 0
	fi

	# Activate if on a plugin-created branch (Angular convention)
	if git_is_plugin_branch "$current_branch"; then
		return 0
	fi

	# Don't activate for other branches (e.g., user's own feature branches)
	return 1
}

# Get current branch name
git_current_branch() {
	git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Check if branch is main/master
git_is_main_branch() {
	local branch="${1:-$(git_current_branch)}"
	[[ "$branch" == "main" || "$branch" == "master" ]]
}

# Get the default branch (main or master)
git_default_branch() {
	# Try to get from remote
	local default
	default=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | cut -d: -f2 | tr -d ' ')

	if [[ -n "$default" ]]; then
		echo "$default"
	elif git show-ref --verify --quiet refs/heads/main; then
		echo "main"
	elif git show-ref --verify --quiet refs/heads/master; then
		echo "master"
	else
		echo "main"
	fi
}

# Find the base branch for the current feature branch
git_find_base_branch() {
	local current
	current="$(git_current_branch)"

	# Try common base branches
	for base in main master develop; do
		if git show-ref --verify --quiet "refs/heads/$base"; then
			# Check if this branch is an ancestor
			if git merge-base --is-ancestor "$base" "$current" 2>/dev/null; then
				echo "$base"
				return 0
			fi
		fi
	done

	# Fall back to default branch
	git_default_branch
}

# Check if there are uncommitted changes
git_has_changes() {
	[[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

# Check if there are staged changes
git_has_staged() {
	! git diff --cached --quiet 2>/dev/null
}

# Get list of changed files
git_changed_files() {
	git status --porcelain | awk '{print $2}'
}

# Get the root of the git repository
git_root() {
	git rev-parse --show-toplevel 2>/dev/null
}

# Create a worktree
git_worktree_add() {
	local path="$1"
	local branch="$2"
	local start_point="${3:-HEAD}"

	git worktree add -b "$branch" "$path" "$start_point"
}

# Remove a worktree
git_worktree_remove() {
	local path="$1"
	local force="${2:-false}"

	if [[ "$force" == "true" ]]; then
		git worktree remove "$path" --force 2>/dev/null || true
	else
		git worktree remove "$path" 2>/dev/null || true
	fi
}

# List all worktrees
git_worktree_list() {
	git worktree list --porcelain
}

# Check if a branch exists
git_branch_exists() {
	local branch="$1"
	git show-ref --verify --quiet "refs/heads/$branch"
}

# Delete a branch
git_branch_delete() {
	local branch="$1"
	local force="${2:-false}"

	if [[ "$force" == "true" ]]; then
		git branch -D "$branch" 2>/dev/null || true
	else
		git branch -d "$branch" 2>/dev/null || true
	fi
}

# Get the SHA of a commit
git_commit_sha() {
	local ref="${1:-HEAD}"
	git rev-parse "$ref" 2>/dev/null
}

# Get the short SHA of a commit
git_commit_sha_short() {
	local ref="${1:-HEAD}"
	git rev-parse --short "$ref" 2>/dev/null
}

# Check if a merge would have conflicts
git_merge_would_conflict() {
	local branch="$1"
	local target="${2:-HEAD}"

	# Try a dry-run merge
	if git merge-tree "$(git merge-base "$target" "$branch")" "$target" "$branch" | grep -q '^<<<<<<<'; then
		return 0 # Would conflict
	fi
	return 1 # No conflict
}

# Get the merge base of two commits
git_merge_base() {
	local ref1="$1"
	local ref2="$2"
	git merge-base "$ref1" "$ref2" 2>/dev/null
}

# Get existing PR number for a branch (returns empty if no PR exists)
git_get_pr_number() {
	local branch="${1:-$(git_current_branch)}"
	gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null || echo ""
}

# Get existing PR body for a branch
git_get_pr_body() {
	local pr_number="$1"
	gh pr view "$pr_number" --json body --jq '.body' 2>/dev/null || echo ""
}

# Update PR body
git_update_pr_body() {
	local pr_number="$1"
	local new_body="$2"
	gh pr edit "$pr_number" --body "$new_body" 2>/dev/null
}

# Format timestamp for display
format_timestamp() {
	date -u +"%Y-%m-%d %H:%M:%S UTC"
}
