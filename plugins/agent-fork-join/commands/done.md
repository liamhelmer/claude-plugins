---
name: "done"
description: "Complete the current branch workflow: check PR status, switch to main, pull changes, and clean up local branch."
---

# /done Command

Complete the current branch workflow by switching to main and cleaning up. This is a **local-only** operation - it does not modify the remote repository.

## When This Command Is Invoked

Execute the following steps in order:

### Step 1: Check Current State

Run these commands to understand the current state:

```bash
# Get current branch
current_branch=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $current_branch"

# Get default branch
default_branch=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | cut -d: -f2 | tr -d ' ' || echo "main")
echo "Default branch: $default_branch"
```

### Step 2: Check PR Status (Local Check Only)

If on a feature branch (feat/, fix/, etc.), check PR state to determine if local cleanup is needed:

```bash
# Check if current branch is a feature branch
if [[ "$current_branch" =~ ^(build|ci|docs|feat|fix|perf|refactor|test)/ ]]; then
    # Get PR number (including merged/closed PRs)
    pr_number=$(gh pr list --head "$current_branch" --state all --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -n "$pr_number" ]]; then
        # Check PR state
        pr_state=$(gh pr view "$pr_number" --json state --jq '.state')

        case "$pr_state" in
        "OPEN")
            echo "PR #$pr_number is still open"
            echo "Merge the PR on GitHub when ready, then run /done again"
            ;;
        "MERGED")
            echo "PR #$pr_number was merged"
            # Mark branch for local deletion
            ;;
        "CLOSED")
            # Check if it was actually merged
            merged_at=$(gh pr view "$pr_number" --json mergedAt --jq '.mergedAt')
            if [[ "$merged_at" != "null" ]]; then
                echo "PR #$pr_number was merged"
                # Mark branch for local deletion
            else
                echo "PR #$pr_number is closed (not merged)"
            fi
            ;;
        esac
    else
        echo "No PR found for this branch"
    fi
fi
```

### Step 3: Switch to Main Branch

```bash
# Stash any uncommitted changes
if [[ -n "$(git status --porcelain)" ]]; then
    git stash push -m "Auto-stash before /done"
fi

# Switch to default branch
git checkout "$default_branch"
```

### Step 4: Pull Latest Changes

```bash
git pull origin "$default_branch"
```

If there are merge conflicts:

1. First try to auto-resolve by accepting remote changes: `git checkout --theirs . && git add -A`
2. If that fails, show the user the conflicting files and ask them to resolve manually

### Step 5: Delete Local Feature Branch

If the PR was merged, delete the local feature branch:

```bash
# Delete local branch if it was marked for deletion
if [[ -n "$branch_to_delete" ]]; then
    git branch -D "$branch_to_delete"
    # Also clean up remote tracking branch
    git branch -dr "origin/$branch_to_delete" 2>/dev/null || true
fi
```

### Step 6: Clean Up Session State

```bash
# Remove session tracking files
rm -f .fork-join/current_session
rm -f .fork-join/tracked_files.txt
```

### Step 7: Run Compact

After all steps complete successfully, run the `/compact` command to consolidate conversation history.

## Error Handling

- **PR is still open**: Inform the user to merge the PR on GitHub first, then run /done again
- **Cannot switch branches**: Check for uncommitted changes and stash them
- **Pull fails with conflicts**: Try auto-resolution first, then ask user to resolve manually if needed

## Output Format

Report progress at each step:

```
=== Completing Branch Workflow ===

Checking PR status for branch feat/my-feature...
PR #42 was merged.

Switching to main branch...
Switched to main

Pulling latest changes...
Already up to date.

Deleting local branch: feat/my-feature...
Deleted local branch: feat/my-feature

=== Workflow Complete ===

Run /compact to consolidate conversation history.
```
