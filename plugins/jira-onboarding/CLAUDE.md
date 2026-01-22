# JIRA Onboarding Plugin

## Purpose

This plugin provides a guided setup flow for connecting beads issue tracking to JIRA Cloud. It validates prerequisites, configures the integration, and performs initial synchronization.

## Activation

The plugin activates when the user runs `/jira-setup`.

## Commands

### /jira-setup - Configure JIRA Integration

Use `/jira-setup` to set up JIRA integration with beads.

The command will:

1. **Check Prerequisites**
   - Verify `JIRA_API_TOKEN` environment variable is set
   - Verify `bd` (beads CLI) is installed and available

2. **Collect Configuration** (if prerequisites met)
   - Ask for JIRA URL (e.g., https://company.atlassian.net)
   - Ask for project key (e.g., PROJ)
   - Ask for optional label filter (e.g., DevEx)
   - Ask for JIRA username/email

3. **Setup beads**
   - Initialize beads if `.beads/` directory doesn't exist
   - Run `bd doctor --fix` to resolve any issues

4. **Configure JIRA**
   - Set `jira.url` config
   - Set `jira.project` config
   - Set `jira.label` config (if provided)
   - Set `jira.username` config

5. **Initial Sync**
   - Run `bd jira sync --pull` to import issues from JIRA

## Prerequisite Instructions

### If JIRA_API_TOKEN is not set

Tell the user:

```
JIRA API token is required but not set.

To get your API token:
1. Go to https://id.atlassian.com/manage-profile/security/api-tokens
2. Click "Create API token"
3. Label it (e.g., "beads-sync")
4. Copy the token

Then set it in your environment:
  export JIRA_API_TOKEN="your_token_here"

For persistence, add this to your shell profile (~/.bashrc, ~/.zshrc, etc.)
```

### If beads CLI is not installed

Tell the user:

```
beads CLI is required but not installed.

Install beads:
  go install github.com/beads-dev/beads/cmd/bd@latest

Or download from: https://github.com/beads-dev/beads/releases

After installation, run /jira-setup again.
```

## Workflow

```
User: /jira-setup
    │
    ▼
┌─────────────────────────────────────────┐
│ Check JIRA_API_TOKEN env var            │
│ Check bd CLI installed                  │
└─────────────────────────────────────────┘
    │
    ├── Missing prerequisites ──▶ Show setup instructions, EXIT
    │
    ▼ Prerequisites met
┌─────────────────────────────────────────┐
│ Ask for JIRA URL                        │
│ Ask for project key                     │
│ Ask for optional label                  │
│ Ask for JIRA username/email             │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Initialize beads if needed              │
│   bd init                               │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Run beads doctor                        │
│   bd doctor --fix                       │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Configure JIRA settings                 │
│   bd config set jira.url "..."          │
│   bd config set jira.project "..."      │
│   bd config set jira.label "..."        │
│   bd config set jira.username "..."     │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Initial sync from JIRA                  │
│   bd jira sync --pull                   │
└─────────────────────────────────────────┘
    │
    ▼
    DONE - Show summary and next steps
```

## Output Format

### Success

```
=== JIRA Integration Setup ===

Checking prerequisites...
  JIRA_API_TOKEN: Set
  beads CLI: Installed (v0.49.0)

Configuring JIRA integration...
  URL: https://company.atlassian.net
  Project: PROJ
  Label: DevEx
  Username: user@company.com

Initializing beads...
  Already initialized

Running diagnostics...
  bd doctor --fix completed

Setting JIRA configuration...
  jira.url = https://company.atlassian.net
  jira.project = PROJ
  jira.label = DevEx
  jira.username = user@company.com

Syncing with JIRA...
  Imported 15 issues

=== Setup Complete ===

Your beads instance is now connected to JIRA project PROJ.

Useful commands:
  bd jira sync --pull   # Pull issues from JIRA
  bd jira sync --push   # Push issues to JIRA
  bd jira sync          # Bidirectional sync
  bd jira status        # Check sync status
```

### Missing Prerequisites

```
=== JIRA Integration Setup ===

Checking prerequisites...

Missing: JIRA_API_TOKEN environment variable

To get your API token:
1. Go to https://id.atlassian.com/manage-profile/security/api-tokens
2. Click "Create API token"
3. Label it (e.g., "beads-sync")
4. Copy the token

Then set it in your environment:
  export JIRA_API_TOKEN="your_token_here"

After setting the token, run /jira-setup again.
```
