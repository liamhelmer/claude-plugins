# Agent Fork-Join Plugin

Multi-agent git workflow orchestrator with isolated worktrees, FIFO merge queue, and automated PR lifecycle management.

## Overview

This plugin enables parallel multi-agent development by giving each agent its own isolated git worktree, then automatically merging their changes through a Rust-based daemon with conflict resolution and PR automation.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Prompt                               │
│              "Build auth, API, and DB modules"                   │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│              UserPromptSubmit Hook                               │
│    • Detects code-changing prompt                                │
│    • Creates feature branch (if needed)                          │
│    • Starts merge daemon                                         │
└──────────────────────────┬──────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│   Agent 1   │  │   Agent 2   │  │   Agent 3   │
│  (worktree) │  │  (worktree) │  │  (worktree) │
│  /src/auth  │  │  /src/api   │  │  /src/db    │
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │
       ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     FIFO Merge Queue                             │
│           Rust daemon handles merge ordering                     │
│           Conflicts → Rebase → Agent fixes → Retry               │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Feature Branch                               │
│              All agent work merged together                      │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Pull Request                                │
│    • Draft PR with original prompt + commit messages             │
│    • Validation (tests, lint, typecheck)                         │
│    • Ready for review when passing                               │
└─────────────────────────────────────────────────────────────────┘
```

## Installation

The plugin requires:

- `git` - Version control
- `gh` - GitHub CLI for PR operations
- `cargo` - Rust compiler (for daemon)

### Build the Daemon

```bash
cd plugins/agent-fork-join/daemon
cargo build --release
```

### Enable the Plugin

Add to your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": ["plugins/agent-fork-join/hooks/on-prompt-submit.sh"],
    "AgentSpawn": ["plugins/agent-fork-join/hooks/on-agent-spawn.sh"],
    "AgentComplete": ["plugins/agent-fork-join/hooks/on-agent-complete.sh"]
  }
}
```

## Configuration

Configuration via environment variables or `plugin.json`:

| Setting               | Default                           | Description                          |
| --------------------- | --------------------------------- | ------------------------------------ |
| `maxConcurrentAgents` | 8                                 | Maximum parallel agents              |
| `mergeStrategy`       | rebase                            | Merge strategy (merge/rebase/squash) |
| `maxMergeRetries`     | 3                                 | Retry limit for conflicts            |
| `testCommand`         | npm test                          | Validation test command              |
| `validationCommands`  | [npm run lint, npm run typecheck] | Additional validations               |
| `defaultReviewers`    | []                                | Default PR reviewers                 |
| `maxReviewers`        | 3                                 | Maximum reviewers to request         |
| `useCodeowners`       | true                              | Parse CODEOWNERS for reviewers       |
| `featureBranchPrefix` | feature/                          | Prefix for feature branches          |
| `agentBranchPrefix`   | agent/                            | Prefix for agent branches            |

## Hooks

### UserPromptSubmit (`on-prompt-submit.sh`)

Triggered when user submits a prompt. Detects if the prompt will make code changes and:

1. Creates a feature branch if not already on one
2. Starts the merge daemon
3. Initializes session state

### AgentSpawn (`on-agent-spawn.sh`)

Triggered when an agent is spawned:

1. Creates an isolated git worktree for the agent
2. Registers the agent with the merge daemon
3. Tracks agent in session state

### AgentComplete (`on-agent-complete.sh`)

Triggered when an agent finishes:

1. Checks if agent made any changes
2. Requests commit message from agent
3. Creates agent branch and commits changes
4. Enqueues branch for merge via daemon

## Merge Daemon

The Rust-based daemon (`daemon/`) handles:

- **FIFO Queue**: First-in-first-out merge ordering
- **Conflict Resolution**: Automatic rebase on conflicts
- **Retry Logic**: Re-queues failed merges for agent fix
- **IPC**: Unix socket communication with hooks
- **State Persistence**: SQLite for crash recovery

### Daemon Commands

```bash
# Start daemon
./daemon/target/release/merge-daemon --repo-path . --socket /tmp/merge-daemon.sock

# Check status (via IPC)
echo '{"type":"STATUS"}' | nc -U /tmp/merge-daemon.sock
```

## Scripts

### `scripts/create-pr.sh`

Creates a draft PR with:

- Original user prompt as description
- Aggregated commit messages from all agents
- Links to related issues (if any)

### `scripts/run-validation.sh`

Runs validation suite:

- Tests (`npm test` or configured command)
- Linting (`npm run lint`)
- Type checking (`npm run typecheck`)

### `scripts/request-reviews.sh`

Requests PR reviews from:

- Configured default reviewers, or
- CODEOWNERS file owners (up to `maxReviewers`)

## File Structure

```
plugins/agent-fork-join/
├── plugin.json              # Plugin manifest
├── README.md                # This file
├── SKILL.md                 # Claude skill definition
├── docs/
│   └── ARCHITECTURE.md      # Detailed architecture docs
├── daemon/                  # Rust merge daemon
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs          # Entry point
│       ├── config.rs        # Configuration
│       ├── queue.rs         # FIFO merge queue
│       ├── merger.rs        # Git merge operations
│       ├── state.rs         # SQLite persistence
│       ├── ipc.rs           # Unix socket server
│       └── error.rs         # Error types
├── hooks/
│   ├── on-prompt-submit.sh  # UserPromptSubmit hook
│   ├── on-agent-spawn.sh    # AgentSpawn hook
│   ├── on-agent-complete.sh # AgentComplete hook
│   └── lib/
│       ├── common.sh        # Shared utilities
│       ├── git-utils.sh     # Git helpers
│       └── daemon-client.sh # Daemon IPC client
└── scripts/
    ├── create-pr.sh         # PR creation
    ├── run-validation.sh    # Test/lint/typecheck
    └── request-reviews.sh   # Review requests
```

## Workflow States

```
IDLE → FEATURE_BRANCH_CREATED → AGENTS_SPAWNED → AGENTS_WORKING
                                                        │
                    ┌───────────────────────────────────┘
                    ▼
            MERGING → (conflict?) → CONFLICT_RESOLUTION → MERGING
                │
                ▼
        PR_CREATED → VALIDATING → (fail?) → VALIDATION_FAILED → VALIDATING
                                    │
                                    ▼
                            READY_FOR_REVIEW → MERGED
```

## Example Usage

```
User: "Build a REST API with authentication, user management, and database models.
       Use 3 agents working in parallel."

Plugin:
1. Creates feature/rest-api-implementation branch
2. Starts merge daemon
3. Spawns 3 agents with isolated worktrees:
   - AuthAgent → /src/auth/
   - UserAgent → /src/users/
   - DBAgent → /src/db/
4. Each agent commits to their branch
5. Daemon merges all branches (handles conflicts)
6. Creates PR with full description
7. Runs validation suite
8. Marks ready and requests reviews
```

## Troubleshooting

### Daemon won't start

- Check socket path permissions
- Verify cargo build completed
- Check for existing daemon process

### Merge conflicts not resolving

- Agent may need to manually fix conflicts
- Check `maxMergeRetries` setting
- Review conflict files in session state

### PR not created

- Verify `gh` CLI is authenticated
- Check remote repository permissions
- Review daemon logs for errors

## Related

- [E2E Tests](../../tests/agent-fork-join/README.md) - End-to-end test suite
- [Architecture](docs/ARCHITECTURE.md) - Detailed technical documentation
