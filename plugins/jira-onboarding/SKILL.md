---
name: "JIRA Onboarding"
description: "Automated JIRA integration setup for beads issue tracking with guided onboarding, prerequisite checking, and bidirectional sync configuration."
---

# JIRA Onboarding

A streamlined plugin that guides users through setting up JIRA integration with beads for bidirectional issue synchronization.

## Overview

This plugin automates the process of connecting your local beads issue tracker to a JIRA Cloud instance. It handles prerequisite checking, beads initialization, JIRA configuration, and initial sync setup.

## Features

- **Prerequisite Validation**: Checks for JIRA_API_TOKEN and beads CLI installation
- **Guided Setup**: Interactive prompts for JIRA URL, project, and optional label
- **Automatic Configuration**: Sets up beads config with JIRA integration settings
- **Health Check**: Runs beads doctor to fix common issues
- **Initial Sync**: Performs first pull from JIRA to import existing issues

## Prerequisites

### 1. JIRA API Token

You need a JIRA API token from your Atlassian account:

1. Go to [Atlassian API Tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
2. Click "Create API token"
3. Give it a label (e.g., "beads-sync")
4. Copy the generated token

Set the token as an environment variable:

```bash
export JIRA_API_TOKEN="your_api_token_here"
```

For persistence, add to your shell profile (~/.bashrc, ~/.zshrc, etc.).

### 2. Beads CLI

Install beads if not already installed:

```bash
# Using go install
go install github.com/beads-dev/beads/cmd/bd@latest

# Or download from releases
# https://github.com/beads-dev/beads/releases
```

Verify installation:

```bash
bd --version
```

## Usage

### Automatic Setup

Run the setup command:

```
/jira-setup
```

The plugin will:

1. Check for JIRA_API_TOKEN environment variable
2. Check for beads CLI installation
3. If missing, provide setup instructions and exit
4. If present, prompt for:
   - JIRA URL (e.g., https://company.atlassian.net)
   - Project key (e.g., PROJ)
   - Optional label filter (e.g., DevEx)
5. Initialize beads if not present
6. Configure JIRA integration
7. Run beads doctor --fix
8. Perform initial sync from JIRA

## Configuration

After setup, these beads config values will be set:

| Key             | Description             | Example                       |
| --------------- | ----------------------- | ----------------------------- |
| `jira.url`      | JIRA Cloud instance URL | https://company.atlassian.net |
| `jira.project`  | JIRA project key        | PROJ                          |
| `jira.label`    | Optional label filter   | DevEx                         |
| `jira.username` | Your JIRA email         | user@company.com              |

The API token is read from the `JIRA_API_TOKEN` environment variable (not stored in config for security).

## Sync Commands

After setup, use these commands:

```bash
# Pull issues from JIRA
bd jira sync --pull

# Push local issues to JIRA
bd jira sync --push

# Bidirectional sync
bd jira sync

# Preview sync without changes
bd jira sync --dry-run

# Check sync status
bd jira status
```

## Troubleshooting

### JIRA_API_TOKEN not set

Ensure the environment variable is exported:

```bash
export JIRA_API_TOKEN="your_token"
```

For permanent setup, add to your shell profile.

### beads not found

Install beads CLI:

```bash
go install github.com/beads-dev/beads/cmd/bd@latest
```

Or download from [releases](https://github.com/beads-dev/beads/releases).

### Authentication failed

1. Verify your API token is correct
2. Ensure JIRA_USERNAME is set to your Atlassian email
3. Check that you have access to the specified project

### Sync issues

Run diagnostics:

```bash
bd doctor --fix
bd jira status
```
