---
name: "Agent Fork-Join"
description: "Multi-agent git workflow orchestrator with isolated worktrees, FIFO merge queue, and automated PR lifecycle management."
---

# Agent Fork-Join

A sophisticated multi-agent orchestration system that enables parallel agent work with isolated git worktrees, automatic conflict resolution, and full PR lifecycle automation.

## Overview

Agent Fork-Join solves the fundamental challenge of multiple AI agents working on the same codebase simultaneously. Each agent operates in an isolated git worktree, and a Rust-based merge daemon coordinates the integration of all changes through a FIFO queue with automatic conflict resolution.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         User Prompt (makes changes)                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    UserPromptSubmit Hook                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 1. Detect if prompt will make changes                            │   │
│  │ 2. Create feature branch (if not on one)                         │   │
│  │ 3. Start merge daemon (if not running)                           │   │
│  │ 4. Initialize session state                                      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Orchestrator Spawns Agents                          │
└─────────────────────────────────────────────────────────────────────────┘
           │                        │                        │
           ▼                        ▼                        ▼
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│   AgentSpawn     │   │   AgentSpawn     │   │   AgentSpawn     │
│   Hook           │   │   Hook           │   │   Hook           │
│                  │   │                  │   │                  │
│ Create worktree  │   │ Create worktree  │   │ Create worktree  │
│ agent/agent-1    │   │ agent/agent-2    │   │ agent/agent-3    │
└──────────────────┘   └──────────────────┘   └──────────────────┘
           │                        │                        │
           ▼                        ▼                        ▼
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│  Agent Works     │   │  Agent Works     │   │  Agent Works     │
│  (isolated)      │   │  (isolated)      │   │  (isolated)      │
└──────────────────┘   └──────────────────┘   └──────────────────┘
           │                        │                        │
           ▼                        ▼                        ▼
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ AgentComplete    │   │ AgentComplete    │   │ AgentComplete    │
│ Hook             │   │ Hook             │   │ Hook             │
│                  │   │                  │   │                  │
│ 1. Check diff    │   │ 1. Check diff    │   │ 1. Check diff    │
│ 2. Get commit    │   │ 2. Get commit    │   │ 2. Get commit    │
│    message       │   │    message       │   │    message       │
│ 3. Create branch │   │ 3. Create branch │   │ 3. Create branch │
│ 4. Commit        │   │ 4. Commit        │   │ 4. Commit        │
│ 5. Queue merge   │   │ 5. Queue merge   │   │ 5. Queue merge   │
└──────────────────┘   └──────────────────┘   └──────────────────┘
           │                        │                        │
           └────────────────────────┼────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Merge Daemon (Rust)                                  │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                      FIFO Merge Queue                            │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                          │   │
│  │  │ Agent-1 │→ │ Agent-2 │→ │ Agent-3 │→ ...                     │   │
│  │  └─────────┘  └─────────┘  └─────────┘                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  For each queued merge:                                                 │
│  1. Attempt merge into feature branch                                   │
│  2. If conflict → rebase agent branch → request agent fix → re-queue   │
│  3. If success → update feature branch → remove from queue              │
│  4. Track merge order and dependencies                                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼ (all agents done, all merges complete)
┌─────────────────────────────────────────────────────────────────────────┐
│                      PR Creation & Validation                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 1. Create draft PR with:                                         │   │
│  │    - Original user prompt as description                         │   │
│  │    - Aggregated commit messages                                  │   │
│  │    - Agent contribution summary                                  │   │
│  │                                                                  │   │
│  │ 2. Run validation suite:                                         │   │
│  │    - Tests (configurable command)                                │   │
│  │    - Linting                                                     │   │
│  │    - Type checking                                               │   │
│  │                                                                  │   │
│  │ 3. If validation fails:                                          │   │
│  │    - Pass results to orchestrator                                │   │
│  │    - Spawn fix agents → cycle repeats                            │   │
│  │                                                                  │   │
│  │ 4. If validation passes:                                         │   │
│  │    - Mark PR as ready for review                                 │   │
│  │    - Request reviews from CODEOWNERS or configured reviewers     │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Merge Daemon (Rust)

A lightweight, high-performance daemon that manages the merge queue.

**Location:** `daemon/`

**Features:**

- FIFO queue with priority support
- Concurrent merge attempts with locking
- Automatic conflict detection
- Rebase orchestration
- IPC via Unix domain socket
- Persistent queue state (survives restarts)
- Metrics and logging

**API:**

```
ENQUEUE <agent-id> <branch-name> <worktree-path>
DEQUEUE <agent-id>
STATUS
CONFLICTS <agent-id>
RETRY <agent-id>
SHUTDOWN
```

### 2. Hooks

#### UserPromptSubmit Hook (`hooks/on-prompt-submit.sh`)

Triggered when user submits a prompt. Determines if the prompt will make changes and initializes the fork-join session.

**Logic:**

1. Analyze prompt for change indicators (keywords: "implement", "fix", "add", "modify", "refactor", "update", etc.)
2. Check current branch - if on main/master, create feature branch
3. Generate session ID
4. Start merge daemon if not running
5. Store session state (original prompt, feature branch, timestamp)

#### AgentSpawn Hook (`hooks/on-agent-spawn.sh`)

Triggered when an agent is spawned by the orchestrator.

**Logic:**

1. Generate unique agent ID
2. Create isolated git worktree: `git worktree add .worktrees/agent-<id> <feature-branch>`
3. Set agent's working directory to worktree
4. Register agent with merge daemon
5. Store agent metadata (spawn time, task description)

#### AgentComplete Hook (`hooks/on-agent-complete.sh`)

Triggered when an agent finishes its work.

**Logic:**

1. Check for changes: `git diff --stat` in agent's worktree
2. If no changes → cleanup worktree, deregister agent
3. If changes exist:
   a. Request commit message from agent (via IPC)
   b. Create agent branch: `agent/<session-id>/<agent-id>`
   c. Stage and commit changes
   d. Enqueue branch for merge
4. Wait for merge result
5. If conflict → prepare conflict info, request agent to fix, re-enqueue
6. Cleanup worktree on success

### 3. Scripts

#### `scripts/create-pr.sh`

Creates a draft PR when all agents complete and merges succeed.

**Inputs:**

- Original user prompt
- List of commit messages
- Agent contribution metadata

**Output:**

- Draft PR with formatted description
- Labels: `draft`, `ai-generated`, `needs-review`

#### `scripts/run-validation.sh`

Runs the configured validation suite.

**Steps:**

1. Run test command
2. Run lint command
3. Run typecheck command
4. Collect results
5. Return pass/fail with details

#### `scripts/request-reviews.sh`

Requests reviews when validation passes.

**Logic:**

1. Parse CODEOWNERS file (if `useCodeowners: true`)
2. Filter to configured `maxReviewers` limit
3. Override with `defaultReviewers` if configured
4. Use `gh pr edit` to request reviews
5. Mark PR as ready for review

## Implementation Plan

### Phase 1: Core Infrastructure

#### 1.1 Merge Daemon (Rust)

- [ ] Create Cargo project structure
- [ ] Implement FIFO queue with Arc<Mutex<VecDeque>>
- [ ] Add Unix domain socket IPC server
- [ ] Implement merge logic with libgit2
- [ ] Add conflict detection and reporting
- [ ] Implement rebase coordination
- [ ] Add persistent state (serde + SQLite)
- [ ] Add logging (tracing crate)
- [ ] Add graceful shutdown handling
- [ ] Write unit tests

**Files:**

```
daemon/
├── Cargo.toml
├── src/
│   ├── main.rs           # Entry point, signal handling
│   ├── lib.rs            # Library exports
│   ├── queue.rs          # FIFO merge queue
│   ├── merger.rs         # Git merge operations
│   ├── ipc.rs            # Unix socket server
│   ├── state.rs          # Persistent state management
│   ├── config.rs         # Configuration loading
│   └── error.rs          # Error types
└── tests/
    ├── queue_test.rs
    └── merger_test.rs
```

**Dependencies:**

```toml
[dependencies]
tokio = { version = "1", features = ["full"] }
git2 = "0.18"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
rusqlite = "0.31"
tracing = "0.1"
tracing-subscriber = "0.3"
thiserror = "1"
```

#### 1.2 Hook Scripts

- [ ] Implement UserPromptSubmit hook
- [ ] Implement AgentSpawn hook
- [ ] Implement AgentComplete hook
- [ ] Add hook configuration loading
- [ ] Add error handling and logging

**Files:**

```
hooks/
├── on-prompt-submit.sh
├── on-agent-spawn.sh
├── on-agent-complete.sh
└── lib/
    ├── common.sh         # Shared functions
    ├── git-utils.sh      # Git helper functions
    └── daemon-client.sh  # Merge daemon IPC client
```

### Phase 2: Git Worktree Management

#### 2.1 Worktree Lifecycle

- [ ] Implement worktree creation with proper isolation
- [ ] Handle worktree cleanup on agent completion
- [ ] Implement worktree recovery (for interrupted sessions)
- [ ] Add worktree locking to prevent conflicts

#### 2.2 Branch Management

- [ ] Implement feature branch creation
- [ ] Implement agent branch creation
- [ ] Handle branch naming conventions
- [ ] Implement branch cleanup after merge

### Phase 3: Merge Queue & Conflict Resolution

#### 3.1 Queue Management

- [ ] Implement FIFO ordering
- [ ] Add priority support for critical fixes
- [ ] Handle queue persistence across daemon restarts
- [ ] Implement queue monitoring and metrics

#### 3.2 Conflict Resolution Flow

- [ ] Detect merge conflicts
- [ ] Generate conflict report for agent
- [ ] Implement rebase coordination
- [ ] Handle conflict resolution retry loop
- [ ] Set maximum retry limit

### Phase 4: PR Lifecycle

#### 4.1 PR Creation

- [ ] Implement draft PR creation script
- [ ] Format PR description from prompt + commits
- [ ] Add agent contribution summary
- [ ] Apply appropriate labels

#### 4.2 Validation Suite

- [ ] Implement configurable test runner
- [ ] Implement lint checker
- [ ] Implement typecheck runner
- [ ] Aggregate and format validation results
- [ ] Implement validation failure → orchestrator feedback loop

#### 4.3 Review Request

- [ ] Parse CODEOWNERS file
- [ ] Implement reviewer selection logic
- [ ] Integrate with `gh` CLI for review requests
- [ ] Mark PR as ready for review

### Phase 5: Integration & Polish

#### 5.1 Configuration

- [ ] Implement configuration file parsing
- [ ] Add per-project overrides
- [ ] Validate configuration on startup

#### 5.2 Error Handling

- [ ] Implement comprehensive error handling
- [ ] Add recovery mechanisms for partial failures
- [ ] Implement session cleanup on errors

#### 5.3 Observability

- [ ] Add structured logging throughout
- [ ] Implement metrics collection
- [ ] Add status reporting commands

## Configuration

```json
{
  "agent-fork-join": {
    "maxConcurrentAgents": 8,
    "mergeStrategy": "rebase",
    "maxMergeRetries": 3,
    "testCommand": "npm test",
    "validationCommands": ["npm run lint", "npm run typecheck"],
    "defaultReviewers": ["@senior-dev", "@tech-lead"],
    "maxReviewers": 3,
    "useCodeowners": true,
    "autoMergeOnSuccess": false,
    "featureBranchPrefix": "feature/",
    "agentBranchPrefix": "agent/",
    "worktreeDir": ".worktrees",
    "daemonSocket": "/tmp/merge-daemon.sock",
    "sessionTimeout": 3600,
    "cleanupOrphanedWorktrees": true
  }
}
```

## Usage

### Automatic Mode

The plugin activates automatically when:

1. A prompt is detected that will make changes
2. Multiple agents are spawned to work on the task

### Manual Commands

```bash
# Check merge daemon status
/agent-fork-join status

# View merge queue
/agent-fork-join queue

# Force cleanup of worktrees
/agent-fork-join cleanup

# View session info
/agent-fork-join session

# Retry failed merge
/agent-fork-join retry <agent-id>

# Cancel session
/agent-fork-join cancel
```

## State Machine

```
┌─────────────┐
│   IDLE      │
└─────────────┘
       │
       │ UserPromptSubmit (change detected)
       ▼
┌─────────────┐
│  STARTED    │ ← Feature branch created, daemon started
└─────────────┘
       │
       │ AgentSpawn
       ▼
┌─────────────┐
│  WORKING    │ ← Agents working in worktrees
└─────────────┘
       │
       │ AgentComplete (last agent)
       ▼
┌─────────────┐
│  MERGING    │ ← Processing merge queue
└─────────────┘
       │
       ├─────────────────────────────┐
       │                             │
       │ All merges succeed          │ Conflict detected
       ▼                             ▼
┌─────────────┐              ┌─────────────┐
│  VALIDATING │              │  RESOLVING  │
└─────────────┘              └─────────────┘
       │                             │
       ├─────────────┐               │ Agent fixes conflict
       │             │               │
       │ Pass        │ Fail          └───────────┐
       ▼             ▼                           │
┌─────────────┐ ┌─────────────┐                  │
│   READY     │ │  FIX_CYCLE  │ ──────────────▶ │
└─────────────┘ └─────────────┘                  │
       │             │                           │
       │             │ Spawn fix agents          │
       │             ▼                           │
       │      ┌─────────────┐                    │
       │      │  WORKING    │ ◀─────────────────┘
       │      └─────────────┘
       │
       │ Request reviews
       ▼
┌─────────────┐
│  COMPLETE   │
└─────────────┘
```

## Error Recovery

### Daemon Crash

- Queue state persisted to SQLite
- On restart, daemon recovers pending merges
- Agents notified to re-enqueue if needed

### Agent Crash

- Worktree preserved for inspection
- Session continues with remaining agents
- Manual cleanup command available

### Merge Deadlock

- Timeout after configurable period
- Escalate to orchestrator for manual resolution
- Option to force-merge or abort

## Security Considerations

1. **Worktree Isolation**: Each agent operates in a completely separate worktree, preventing accidental interference
2. **Branch Protection**: Agent branches are prefixed and namespaced to prevent collision with user branches
3. **Daemon Socket**: Unix socket with restricted permissions
4. **Credential Handling**: Uses system git credential helpers, no credential storage

## Performance

- Worktree creation: ~100ms per agent
- Merge operation: ~50-200ms depending on diff size
- Queue throughput: ~10 merges/second
- Memory overhead: ~5MB per active worktree

## Dependencies

- Git 2.20+ (worktree support)
- Rust 1.70+ (for daemon compilation)
- gh CLI (for PR operations)
- Unix-like OS (for domain sockets)

## Troubleshooting

### Issue: Daemon won't start

**Solution**: Check if socket file exists at `/tmp/merge-daemon.sock`. Remove stale socket and retry.

### Issue: Worktree creation fails

**Solution**: Ensure `.worktrees` directory exists and is writable. Check for branch name conflicts.

### Issue: Merge conflicts not detected

**Solution**: Ensure merge daemon has read access to all worktrees. Check daemon logs.

### Issue: PR creation fails

**Solution**: Verify `gh` CLI is authenticated. Check for branch push permissions.

## Resources

- [Git Worktrees Documentation](https://git-scm.com/docs/git-worktree)
- [libgit2 Rust Bindings](https://docs.rs/git2/)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
