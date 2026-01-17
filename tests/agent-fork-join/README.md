# Agent Fork-Join E2E Tests

End-to-end test suite for the `agent-fork-join` plugin.

## Overview

This test suite validates the complete workflow of the agent-fork-join plugin by:

1. Creating a unique test repository on GitHub
2. Initializing it with proper configuration files
3. Running Claude with a prompt that spawns 5 concurrent agents
4. Verifying the expected git branches, commits, and PR are created
5. Optionally cleaning up the test repository

## Prerequisites

- **gh CLI**: Authenticated with GitHub (`gh auth login`)
- **claude CLI**: Installed and configured
- **cargo**: For building the Rust daemon
- **jq**: For JSON parsing
- **git**: For repository operations

## Non-Interactive Mode

The test runs Claude in fully non-interactive mode using:

- `--dangerously-skip-permissions`: Skips all permission prompts
- `--allowedTools`: Explicitly allows required tools (Bash, Read, Write, Edit, etc.)
- `.claude/settings.json`: Pre-configures permissions for the test repository

This allows the test to run without human intervention.

## Quick Start

```bash
# Run the E2E test (keeps repository for inspection)
./e2e-test.sh

# Run with automatic cleanup
./e2e-test.sh --clean

# Run with verbose output
./e2e-test.sh --verbose

# Run in a different GitHub org/user
./e2e-test.sh --org your-username
```

## Test Script Options

### e2e-test.sh

```
Usage: ./e2e-test.sh [OPTIONS]

Options:
  --clean           Clean up the test repository after test completes
  --org ORG         GitHub organization/user (default: liamhelmer)
  --timeout SECS    Timeout in seconds (default: 600)
  --repo NAME       Use specific repo name instead of generated one
  --verbose, -v     Verbose output
  --help, -h        Show help message
```

### cleanup.sh

```
Usage: ./cleanup.sh [OPTIONS] [REPO_NAME]

Options:
  --all              Delete all test repositories (fork-join-test-*)
  --list             List test repositories without deleting
  --dry-run          Show what would be deleted
  --org ORG          GitHub organization/user (default: liamhelmer)
  --help, -h         Show help message
```

## What the Test Validates

| Check          | Description                                                    |
| -------------- | -------------------------------------------------------------- |
| Feature Branch | A `feature/` branch was created                                |
| Commits        | At least 5 commits exist (one per agent)                       |
| Pull Request   | A PR was created to merge the feature branch                   |
| Directories    | All 5 module directories exist (`src/auth/`, `src/api/`, etc.) |

## Test Repository Structure

The test creates a repository with:

```
test-repo/
├── CLAUDE.md           # Project instructions
├── AGENTS.md           # Agent definitions (5 agents)
├── package.json        # For validation scripts
└── .claude/
    ├── settings.json   # Hook configuration
    └── plugins/
        └── agent-fork-join/
            ├── plugin.json
            ├── SKILL.md
            ├── hooks/
            │   ├── on-prompt-submit.sh
            │   ├── on-agent-spawn.sh
            │   └── on-agent-complete.sh
            ├── scripts/
            └── daemon/
                └── target/release/merge-daemon
```

## Expected Workflow

When the test runs:

1. **Prompt Submitted**: Hook detects code-changing prompt, creates feature branch
2. **Agents Spawn**: Each of 5 agents gets its own git worktree
3. **Agents Work**: Each agent creates files in their assigned directory
4. **Agents Complete**: Changes are committed to agent branches
5. **Merge Queue**: Daemon merges all agent branches into feature branch
6. **PR Created**: Draft PR is created with aggregated commit messages
7. **Validation**: Tests/lint run on the merged code
8. **Ready**: PR is marked ready for review

## Logs

Test logs are saved to:

```
tests/agent-fork-join/logs/fork-join-test-TIMESTAMP-claude.log
```

## Troubleshooting

### Test times out

- Increase timeout: `./e2e-test.sh --timeout 900`
- Check Claude is responding: `claude --version`

### Repository already exists

- Use a different name: `./e2e-test.sh --repo my-unique-name`
- Clean up old repos: `./cleanup.sh --list` then `./cleanup.sh REPO_NAME`

### Missing prerequisites

The test will check for required tools and report any missing ones.

### Build failures

If the Rust daemon isn't built:

```bash
cd ../../plugins/agent-fork-join/daemon
cargo build --release
```

## Cleaning Up

After testing, clean up repositories:

```bash
# List all test repos
./cleanup.sh --list

# Delete all test repos (with confirmation)
./cleanup.sh --all

# Preview what would be deleted
./cleanup.sh --dry-run --all

# Delete specific repo
./cleanup.sh fork-join-test-20240115-123456
```
