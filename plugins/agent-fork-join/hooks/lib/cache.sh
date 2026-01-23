#!/usr/bin/env bash
# Unified caching layer for agent-fork-join
# Caches PR info, beads data, and git state to avoid API calls

# Cache directory inside .fork-join
CACHE_DIR="${FORK_JOIN_STATE_DIR:-.fork-join}/cache"
CACHE_TTL_SECONDS="${CACHE_TTL_SECONDS:-300}" # 5 minute default TTL

# Initialize cache directory
cache_init() {
	mkdir -p "$CACHE_DIR"
}

# Get cache file age in seconds (returns 999999 if file doesn't exist)
_cache_age() {
	local file="$1"
	if [[ ! -f "$file" ]]; then
		echo "999999"
		return
	fi
	local now
	now=$(date +%s)
	local mtime
	# macOS uses -f %m, Linux uses -c %Y
	mtime=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo 0)
	echo $((now - mtime))
}

# Check if cache is valid (exists and not expired)
_cache_valid() {
	local file="$1"
	local ttl="${2:-$CACHE_TTL_SECONDS}"
	local age
	age=$(_cache_age "$file")
	[[ $age -lt $ttl ]]
}

# ==========================================
# PR Cache Functions
# ==========================================

PR_CACHE_FILE="${CACHE_DIR}/pr-info.json"

# Cache PR info for current branch
# Usage: cache_pr_info [branch]
cache_pr_info() {
	local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
	cache_init

	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi

	# Get PR info from GitHub (single API call)
	local pr_json
	pr_json=$(gh pr list --head "$branch" --state all --json number,state,body,title,url,mergedAt --jq '.[0] // empty' 2>/dev/null)

	if [[ -z "$pr_json" ]]; then
		# No PR found - cache that fact
		echo '{"exists": false, "branch": "'"$branch"'", "cached_at": '"$(date +%s)"'}' >"$PR_CACHE_FILE"
		return 1
	fi

	# Add metadata to cached data
	echo "$pr_json" | jq --arg branch "$branch" --arg cached "$(date +%s)" \
		'. + {exists: true, branch: $branch, cached_at: ($cached | tonumber)}' >"$PR_CACHE_FILE"
	return 0
}

# Get cached PR number (refreshes if stale)
# Usage: cache_get_pr_number [branch]
cache_get_pr_number() {
	local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"

	# Check if cache is valid for this branch
	if _cache_valid "$PR_CACHE_FILE" && [[ -f "$PR_CACHE_FILE" ]]; then
		local cached_branch
		cached_branch=$(jq -r '.branch // empty' "$PR_CACHE_FILE" 2>/dev/null)
		if [[ "$cached_branch" == "$branch" ]]; then
			local exists
			exists=$(jq -r '.exists // false' "$PR_CACHE_FILE" 2>/dev/null)
			if [[ "$exists" == "true" ]]; then
				jq -r '.number // empty' "$PR_CACHE_FILE" 2>/dev/null
				return 0
			fi
			return 1
		fi
	fi

	# Cache miss - refresh
	if cache_pr_info "$branch"; then
		jq -r '.number // empty' "$PR_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Get cached PR body
cache_get_pr_body() {
	local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"

	if _cache_valid "$PR_CACHE_FILE" && [[ -f "$PR_CACHE_FILE" ]]; then
		local cached_branch
		cached_branch=$(jq -r '.branch // empty' "$PR_CACHE_FILE" 2>/dev/null)
		if [[ "$cached_branch" == "$branch" ]]; then
			jq -r '.body // empty' "$PR_CACHE_FILE" 2>/dev/null
			return 0
		fi
	fi

	# Cache miss - refresh
	if cache_pr_info "$branch"; then
		jq -r '.body // empty' "$PR_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Get cached PR state (OPEN, MERGED, CLOSED)
cache_get_pr_state() {
	local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"

	if _cache_valid "$PR_CACHE_FILE" && [[ -f "$PR_CACHE_FILE" ]]; then
		local cached_branch
		cached_branch=$(jq -r '.branch // empty' "$PR_CACHE_FILE" 2>/dev/null)
		if [[ "$cached_branch" == "$branch" ]]; then
			jq -r '.state // empty' "$PR_CACHE_FILE" 2>/dev/null
			return 0
		fi
	fi

	if cache_pr_info "$branch"; then
		jq -r '.state // empty' "$PR_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Get cached PR URL
cache_get_pr_url() {
	local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"

	if _cache_valid "$PR_CACHE_FILE" && [[ -f "$PR_CACHE_FILE" ]]; then
		local cached_branch
		cached_branch=$(jq -r '.branch // empty' "$PR_CACHE_FILE" 2>/dev/null)
		if [[ "$cached_branch" == "$branch" ]]; then
			jq -r '.url // empty' "$PR_CACHE_FILE" 2>/dev/null
			return 0
		fi
	fi

	if cache_pr_info "$branch"; then
		jq -r '.url // empty' "$PR_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Check if PR was merged (from cache)
cache_pr_was_merged() {
	local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"

	local state
	state=$(cache_get_pr_state "$branch")

	if [[ "$state" == "MERGED" ]]; then
		return 0
	fi

	# Check mergedAt for CLOSED state (could be merged)
	if [[ "$state" == "CLOSED" ]] && [[ -f "$PR_CACHE_FILE" ]]; then
		local merged_at
		merged_at=$(jq -r '.mergedAt // "null"' "$PR_CACHE_FILE" 2>/dev/null)
		if [[ "$merged_at" != "null" && -n "$merged_at" ]]; then
			return 0
		fi
	fi

	return 1
}

# Force refresh PR cache
cache_refresh_pr() {
	local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
	rm -f "$PR_CACHE_FILE"
	cache_pr_info "$branch"
}

# ==========================================
# Beads/Issue Cache Functions
# ==========================================

ISSUE_CACHE_FILE="${CACHE_DIR}/issue-info.json"

# Cache current beads issue info
cache_issue_info() {
	cache_init

	local beads_dir=".beads"
	local current_issue_file="${beads_dir}/current-issue"

	if [[ ! -f "$current_issue_file" ]]; then
		echo '{"exists": false, "cached_at": '"$(date +%s)"'}' >"$ISSUE_CACHE_FILE"
		return 1
	fi

	local issue_id
	issue_id=$(cat "$current_issue_file" 2>/dev/null | tr -d '[:space:]')

	if [[ -z "$issue_id" ]]; then
		echo '{"exists": false, "cached_at": '"$(date +%s)"'}' >"$ISSUE_CACHE_FILE"
		return 1
	fi

	if ! command -v bd >/dev/null 2>&1; then
		# No bd CLI - just store issue ID
		echo '{"exists": true, "id": "'"$issue_id"'", "cached_at": '"$(date +%s)"'}' >"$ISSUE_CACHE_FILE"
		return 0
	fi

	# Get full issue info from beads
	local issue_json
	issue_json=$(bd show "$issue_id" --json 2>/dev/null)

	if [[ -z "$issue_json" ]]; then
		echo '{"exists": true, "id": "'"$issue_id"'", "cached_at": '"$(date +%s)"'}' >"$ISSUE_CACHE_FILE"
		return 0
	fi

	# Extract JIRA key from external_ref
	local jira_key=""
	local external_ref
	external_ref=$(echo "$issue_json" | jq -r '.external_ref // empty' 2>/dev/null)
	if [[ -n "$external_ref" && "$external_ref" == *"/browse/"* ]]; then
		jira_key=$(echo "$external_ref" | sed 's|.*/browse/||')
	fi

	# Add metadata
	echo "$issue_json" | jq --arg jira "$jira_key" --arg cached "$(date +%s)" \
		'. + {exists: true, jira_key: $jira, cached_at: ($cached | tonumber)}' >"$ISSUE_CACHE_FILE"
	return 0
}

# Get cached issue ID
cache_get_issue_id() {
	if _cache_valid "$ISSUE_CACHE_FILE" 600 && [[ -f "$ISSUE_CACHE_FILE" ]]; then
		local exists
		exists=$(jq -r '.exists // false' "$ISSUE_CACHE_FILE" 2>/dev/null)
		if [[ "$exists" == "true" ]]; then
			jq -r '.id // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
			return 0
		fi
		return 1
	fi

	# Cache miss - refresh
	if cache_issue_info; then
		jq -r '.id // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Get cached JIRA key
cache_get_jira_key() {
	if _cache_valid "$ISSUE_CACHE_FILE" 600 && [[ -f "$ISSUE_CACHE_FILE" ]]; then
		jq -r '.jira_key // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
		return 0
	fi

	if cache_issue_info; then
		jq -r '.jira_key // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Get cached issue status
cache_get_issue_status() {
	if _cache_valid "$ISSUE_CACHE_FILE" 600 && [[ -f "$ISSUE_CACHE_FILE" ]]; then
		jq -r '.status // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
		return 0
	fi

	if cache_issue_info; then
		jq -r '.status // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Get cached JIRA URL (external_ref)
cache_get_jira_url() {
	if _cache_valid "$ISSUE_CACHE_FILE" 600 && [[ -f "$ISSUE_CACHE_FILE" ]]; then
		jq -r '.external_ref // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
		return 0
	fi

	if cache_issue_info; then
		jq -r '.external_ref // empty' "$ISSUE_CACHE_FILE" 2>/dev/null
		return 0
	fi
	return 1
}

# Update cached issue status
cache_update_issue_status() {
	local new_status="$1"
	if [[ -f "$ISSUE_CACHE_FILE" ]]; then
		local tmp_file="${ISSUE_CACHE_FILE}.tmp"
		jq --arg status "$new_status" '.status = $status' "$ISSUE_CACHE_FILE" >"$tmp_file" 2>/dev/null &&
			mv "$tmp_file" "$ISSUE_CACHE_FILE"
	fi
}

# ==========================================
# Git State Cache Functions
# ==========================================

GIT_CACHE_FILE="${CACHE_DIR}/git-state.json"

# Cache git state (branch, remote, etc)
cache_git_state() {
	cache_init

	local current_branch
	current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

	local remote_url
	remote_url=$(git remote get-url origin 2>/dev/null || echo "")

	local is_github="false"
	if [[ "$remote_url" == *"github.com"* ]]; then
		is_github="true"
	fi

	local default_branch=""
	if git show-ref --verify --quiet refs/heads/main; then
		default_branch="main"
	elif git show-ref --verify --quiet refs/heads/master; then
		default_branch="master"
	fi

	local is_main="false"
	if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
		is_main="true"
	fi

	local is_plugin_branch="false"
	if [[ "$current_branch" =~ ^(build|ci|docs|feat|fix|perf|refactor|test)/ ]]; then
		is_plugin_branch="true"
	fi

	cat >"$GIT_CACHE_FILE" <<EOF
{
  "branch": "$current_branch",
  "remote_url": "$remote_url",
  "is_github": $is_github,
  "default_branch": "$default_branch",
  "is_main": $is_main,
  "is_plugin_branch": $is_plugin_branch,
  "cached_at": $(date +%s)
}
EOF
}

# Get cached git state (refreshes if branch changed)
_ensure_git_cache() {
	local current_branch
	current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

	if [[ -f "$GIT_CACHE_FILE" ]]; then
		local cached_branch
		cached_branch=$(jq -r '.branch // empty' "$GIT_CACHE_FILE" 2>/dev/null)
		if [[ "$cached_branch" == "$current_branch" ]] && _cache_valid "$GIT_CACHE_FILE" 60; then
			return 0
		fi
	fi

	cache_git_state
}

# Get current branch (cached)
cache_get_branch() {
	_ensure_git_cache
	jq -r '.branch // empty' "$GIT_CACHE_FILE" 2>/dev/null
}

# Check if GitHub repo (cached)
cache_is_github() {
	_ensure_git_cache
	local result
	result=$(jq -r '.is_github // "false"' "$GIT_CACHE_FILE" 2>/dev/null)
	[[ "$result" == "true" ]]
}

# Check if on main branch (cached)
cache_is_main_branch() {
	_ensure_git_cache
	local result
	result=$(jq -r '.is_main // "false"' "$GIT_CACHE_FILE" 2>/dev/null)
	[[ "$result" == "true" ]]
}

# Check if on plugin-created branch (cached)
cache_is_plugin_branch() {
	_ensure_git_cache
	local result
	result=$(jq -r '.is_plugin_branch // "false"' "$GIT_CACHE_FILE" 2>/dev/null)
	[[ "$result" == "true" ]]
}

# Get default branch (cached)
cache_get_default_branch() {
	_ensure_git_cache
	jq -r '.default_branch // "main"' "$GIT_CACHE_FILE" 2>/dev/null
}

# ==========================================
# Session State Cache
# ==========================================

SESSION_CACHE_FILE="${CACHE_DIR}/session-state.json"

# Store session info
cache_session_start() {
	local branch="$1"
	local prompt="$2"
	local session_id="${3:-session-$(date +%s)}"

	cache_init

	cat >"$SESSION_CACHE_FILE" <<EOF
{
  "session_id": "$session_id",
  "branch": "$branch",
  "prompt": $(echo "$prompt" | jq -Rs .),
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "prompts": []
}
EOF
	echo "$session_id"
}

# Add prompt to session history
cache_session_add_prompt() {
	local prompt="$1"
	local timestamp
	timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

	if [[ -f "$SESSION_CACHE_FILE" ]]; then
		local tmp_file="${SESSION_CACHE_FILE}.tmp"
		jq --arg prompt "$prompt" --arg ts "$timestamp" \
			'.prompts += [{"prompt": $prompt, "timestamp": $ts}]' \
			"$SESSION_CACHE_FILE" >"$tmp_file" 2>/dev/null &&
			mv "$tmp_file" "$SESSION_CACHE_FILE"
	fi
}

# Get session prompt
cache_get_session_prompt() {
	if [[ -f "$SESSION_CACHE_FILE" ]]; then
		jq -r '.prompt // empty' "$SESSION_CACHE_FILE" 2>/dev/null
	fi
}

# Get session ID
cache_get_session_id() {
	if [[ -f "$SESSION_CACHE_FILE" ]]; then
		jq -r '.session_id // empty' "$SESSION_CACHE_FILE" 2>/dev/null
	fi
}

# Get session branch
cache_get_session_branch() {
	if [[ -f "$SESSION_CACHE_FILE" ]]; then
		jq -r '.branch // empty' "$SESSION_CACHE_FILE" 2>/dev/null
	fi
}

# ==========================================
# Cache Cleanup
# ==========================================

# Clear all caches
cache_clear_all() {
	rm -rf "$CACHE_DIR"
}

# Clear PR cache only
cache_clear_pr() {
	rm -f "$PR_CACHE_FILE"
}

# Clear issue cache only
cache_clear_issue() {
	rm -f "$ISSUE_CACHE_FILE"
}

# Clear session cache
cache_clear_session() {
	rm -f "$SESSION_CACHE_FILE"
}
