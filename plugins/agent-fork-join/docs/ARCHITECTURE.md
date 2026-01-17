# Agent Fork-Join Architecture

## System Overview

Agent Fork-Join is a multi-agent orchestration system designed to enable parallel AI agent work on a shared codebase without conflicts. It uses git worktrees for isolation and a Rust-based merge daemon for coordination.

## Core Design Principles

### 1. Isolation First

Every agent operates in a completely isolated git worktree. This ensures:

- No accidental file overwrites between agents
- Independent staging areas
- Clean diff detection per agent

### 2. FIFO Fairness

The merge queue processes changes in the order they complete, ensuring:

- Predictable merge order
- No starvation of slow agents
- Clear audit trail of changes

### 3. Graceful Conflict Resolution

When conflicts occur:

- The conflicting agent is notified with full context
- The agent's branch is rebased onto the latest feature branch
- The agent resolves conflicts and re-submits
- Process repeats until successful or max retries exceeded

### 4. Full Lifecycle Automation

From prompt to merged PR:

- Automatic feature branch creation
- Automatic PR creation with rich metadata
- Automatic validation
- Automatic review requests

## Component Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Claude Code                               │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                     Hook System                              ││
│  │  ┌───────────────┬───────────────┬───────────────┐          ││
│  │  │UserPrompt     │ AgentSpawn    │ AgentComplete │          ││
│  │  │Submit         │               │               │          ││
│  │  └───────┬───────┴───────┬───────┴───────┬───────┘          ││
│  └──────────┼───────────────┼───────────────┼──────────────────┘│
└─────────────┼───────────────┼───────────────┼───────────────────┘
              │               │               │
              ▼               ▼               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Shell Script Hooks                            │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ on-prompt-submit.sh  on-agent-spawn.sh  on-agent-complete.sh││
│  └─────────────────────────────────────────────────────────────┘│
│                              │                                   │
│                    ┌─────────┴─────────┐                        │
│                    ▼                   ▼                        │
│            ┌──────────────┐    ┌──────────────┐                 │
│            │  Git Ops     │    │  IPC Client  │                 │
│            │  (worktrees) │    │  (daemon)    │                 │
│            └──────────────┘    └──────┬───────┘                 │
└──────────────────────────────────────┼──────────────────────────┘
                                       │
                         Unix Domain Socket
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Merge Daemon (Rust)                           │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                                                              ││
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐             ││
│  │  │   Queue    │  │   Merger   │  │   State    │             ││
│  │  │  Manager   │  │   Engine   │  │  Persister │             ││
│  │  └────────────┘  └────────────┘  └────────────┘             ││
│  │         │               │               │                    ││
│  │         └───────────────┴───────────────┘                    ││
│  │                         │                                    ││
│  │                         ▼                                    ││
│  │                  ┌────────────┐                              ││
│  │                  │  libgit2   │                              ││
│  │                  └────────────┘                              ││
│  │                                                              ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

### 1. Session Initialization

```
User Prompt → UserPromptSubmit Hook
                     │
                     ├─► Detect change intent (keyword analysis)
                     │
                     ├─► Check/Create feature branch
                     │
                     ├─► Generate session ID (UUID)
                     │
                     ├─► Start merge daemon (if needed)
                     │
                     └─► Store session state
                              │
                              ▼
                     ┌─────────────────┐
                     │ Session State   │
                     │ - session_id    │
                     │ - feature_branch│
                     │ - original_prompt│
                     │ - start_time    │
                     │ - agents: []    │
                     └─────────────────┘
```

### 2. Agent Lifecycle

```
Orchestrator spawns agent
         │
         ▼
   AgentSpawn Hook
         │
         ├─► Generate agent ID
         │
         ├─► git worktree add .worktrees/agent-{id} {feature-branch}
         │
         ├─► Register with daemon: REGISTER {agent-id}
         │
         └─► Update session state
                  │
                  ▼
         Agent works in worktree
                  │
                  ▼
       AgentComplete Hook
                  │
                  ├─► git diff --stat (in worktree)
                  │
                  ├─► If no changes:
                  │        └─► Cleanup, deregister, return
                  │
                  ├─► If changes:
                  │        ├─► Request commit message from agent
                  │        ├─► Create branch: agent/{session}/{agent-id}
                  │        ├─► git add -A && git commit
                  │        └─► ENQUEUE {agent-id} {branch} {worktree}
                  │
                  └─► Wait for merge result
                           │
                           ├─► SUCCESS: Cleanup worktree
                           │
                           └─► CONFLICT: Rebase, request fix, re-enqueue
```

### 3. Merge Queue Processing

```
┌─────────────────────────────────────────────────────────┐
│                   Merge Queue                            │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐    │
│  │Agent-1  │→ │Agent-2  │→ │Agent-3  │→ │Agent-4  │    │
│  │branch-1 │  │branch-2 │  │branch-3 │  │branch-4 │    │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘    │
└─────────────────────────────────────────────────────────┘
         │
         ▼
    Dequeue head
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│                 Merge Attempt                            │
│                                                          │
│   git checkout {feature-branch}                         │
│   git merge {agent-branch} --no-ff                      │
│                                                          │
│   ┌──────────────────────────────────────────────────┐  │
│   │                    Result                         │  │
│   │                                                   │  │
│   │  SUCCESS ────► Update feature branch             │  │
│   │               Notify agent: MERGED               │  │
│   │               Remove from queue                  │  │
│   │                                                   │  │
│   │  CONFLICT ───► Notify agent: CONFLICT {files}    │  │
│   │               Rebase agent branch                │  │
│   │               Request resolution                 │  │
│   │               Re-enqueue (at head or tail)       │  │
│   └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Protocol Specification

### IPC Protocol (Unix Domain Socket)

All messages are newline-delimited JSON:

```json
// Request
{
  "type": "ENQUEUE",
  "agent_id": "agent-abc123",
  "branch": "agent/session-xyz/agent-abc123",
  "worktree": "/path/to/.worktrees/agent-abc123"
}

// Response
{
  "status": "OK",
  "position": 3
}
```

#### Commands

| Command   | Request                              | Response                               |
| --------- | ------------------------------------ | -------------------------------------- |
| REGISTER  | `{type, agent_id}`                   | `{status: OK}`                         |
| ENQUEUE   | `{type, agent_id, branch, worktree}` | `{status, position}`                   |
| DEQUEUE   | `{type, agent_id}`                   | `{status}`                             |
| STATUS    | `{type}`                             | `{queue_length, processing, agents[]}` |
| CONFLICTS | `{type, agent_id}`                   | `{files[], base_commit}`               |
| RETRY     | `{type, agent_id}`                   | `{status, position}`                   |
| WAIT      | `{type, agent_id}`                   | `{result: MERGED\|CONFLICT, details}`  |
| SHUTDOWN  | `{type}`                             | `{status}`                             |

### Session State Schema

```json
{
  "session_id": "uuid",
  "feature_branch": "feature/implement-auth",
  "base_branch": "main",
  "original_prompt": "Implement OAuth2 authentication...",
  "created_at": "2024-01-15T10:30:00Z",
  "state": "WORKING|MERGING|VALIDATING|COMPLETE",
  "agents": [
    {
      "agent_id": "agent-abc123",
      "worktree": "/path/.worktrees/agent-abc123",
      "branch": "agent/session-xyz/agent-abc123",
      "task": "Implement login endpoint",
      "status": "WORKING|COMPLETE|MERGED|CONFLICT",
      "commit_message": "feat(auth): implement login endpoint",
      "merged_at": null,
      "conflict_count": 0
    }
  ],
  "merged_commits": [],
  "pr_number": null,
  "validation_results": null
}
```

## Git Operations

### Worktree Management

```bash
# Create worktree for agent
git worktree add .worktrees/agent-{id} {feature-branch} -b agent/{session}/{id}

# List worktrees
git worktree list

# Remove worktree
git worktree remove .worktrees/agent-{id}

# Prune stale worktrees
git worktree prune
```

### Branch Operations

```bash
# Create feature branch
git checkout -b feature/{slug} main

# Create agent branch (from worktree)
cd .worktrees/agent-{id}
git checkout -b agent/{session}/{id}

# Rebase agent branch on updated feature
git rebase feature/{slug}
```

### Merge Operations (Daemon)

```rust
// Pseudocode for merge operation
fn merge_agent_branch(agent: &Agent, feature_branch: &str) -> MergeResult {
    let repo = Repository::open(".")?;

    // Checkout feature branch
    repo.checkout_branch(feature_branch)?;

    // Attempt merge
    let agent_commit = repo.find_branch(&agent.branch)?.get_commit();
    let merge_result = repo.merge(&[agent_commit])?;

    if merge_result.has_conflicts() {
        // Get conflict files
        let conflicts = repo.index()?.conflicts()?
            .map(|c| c.path)
            .collect();

        MergeResult::Conflict { files: conflicts }
    } else {
        // Commit the merge
        repo.commit(
            "HEAD",
            &format!("Merge agent {} into {}", agent.id, feature_branch),
            &merge_result.tree()?,
            &[&repo.head()?.peel_to_commit()?, &agent_commit]
        )?;

        MergeResult::Success
    }
}
```

## Validation Pipeline

```
┌──────────────────────────────────────────────────────┐
│                 Validation Pipeline                   │
│                                                       │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐            │
│  │  Tests  │ → │  Lint   │ → │  Types  │ → Pass/Fail│
│  └─────────┘   └─────────┘   └─────────┘            │
│                                                       │
│  Each step:                                          │
│  - Run configured command                            │
│  - Capture stdout/stderr                             │
│  - Record exit code                                  │
│  - Continue or fail-fast based on config             │
│                                                       │
└──────────────────────────────────────────────────────┘
         │
         ▼
    ┌─────────────────────────────────────────────┐
    │              On Failure                      │
    │                                              │
    │  1. Parse failure output                    │
    │  2. Identify failing tests/files            │
    │  3. Generate fix request for orchestrator   │
    │  4. Spawn fix agents (back to WORKING)      │
    │                                              │
    └─────────────────────────────────────────────┘
         │
         ▼
    ┌─────────────────────────────────────────────┐
    │              On Success                      │
    │                                              │
    │  1. Mark PR as ready                        │
    │  2. Parse CODEOWNERS                        │
    │  3. Request reviews                         │
    │  4. Apply labels                            │
    │                                              │
    └─────────────────────────────────────────────┘
```

## Error Handling

### Recovery Strategies

| Error           | Recovery                                                 |
| --------------- | -------------------------------------------------------- |
| Daemon crash    | Restart from persisted state                             |
| Agent crash     | Preserve worktree, mark agent as failed, continue others |
| Merge deadlock  | Timeout → escalate to orchestrator                       |
| Git corruption  | Abort session, cleanup, report                           |
| Network failure | Retry with exponential backoff                           |

### Cleanup Procedures

```bash
# Session cleanup
cleanup_session() {
    session_id=$1

    # Remove all agent worktrees
    for worktree in .worktrees/agent-*; do
        git worktree remove "$worktree" --force
    done

    # Remove agent branches
    git branch | grep "agent/$session_id" | xargs git branch -D

    # Remove session state file
    rm -f ".fork-join/$session_id.json"

    # Notify daemon
    echo '{"type":"SESSION_END","session_id":"'$session_id'"}' | nc -U /tmp/merge-daemon.sock
}
```

## Performance Considerations

### Worktree Creation

- Use `--no-checkout` initially for speed
- Sparse checkout for large repos
- Consider shallow clones for CI environments

### Merge Daemon

- Single-threaded queue processing (avoids race conditions)
- Async I/O for socket handling
- Memory-mapped file for state persistence

### Scalability

- Maximum 8 concurrent agents by default (configurable)
- Queue depth limit of 100 entries
- Automatic cleanup of stale sessions after 1 hour
