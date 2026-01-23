---
name: "setup"
description: "Set up JIRA integration with beads for bidirectional issue synchronization."
---

# /jira:setup Command

Configure JIRA Cloud integration with beads issue tracking. This command validates prerequisites, guides you through configuration, and performs initial synchronization.

## When This Command Is Invoked

Execute the following steps in order:

### Step 1: Check Prerequisites

Check for required prerequisites before proceeding:

```bash
# Check for JIRA_API_TOKEN
if [[ -z "$JIRA_API_TOKEN" ]]; then
    echo "JIRA_API_TOKEN not set"
    # Exit and show instructions
fi

# Check for beads CLI
if ! command -v bd &> /dev/null; then
    echo "beads CLI not installed"
    # Exit and show instructions
fi
```

**If JIRA_API_TOKEN is not set**, tell the user:

```
Missing: JIRA_API_TOKEN environment variable

To get your API token:
1. Go to https://id.atlassian.com/manage-profile/security/api-tokens
2. Click "Create API token"
3. Label it (e.g., "beads-sync")
4. Copy the token

Then set it in your environment:
  export JIRA_API_TOKEN="your_token_here"

For persistence, add to your shell profile (~/.bashrc, ~/.zshrc, etc.)

After setting the token, run /jira:setup again.
```

**If beads CLI is not installed**, tell the user:

```
Missing: beads CLI (bd command)

Install beads:
  go install github.com/beads-dev/beads/cmd/bd@latest

Or download from: https://github.com/beads-dev/beads/releases

After installation, run /jira:setup again.
```

**IMPORTANT**: If any prerequisite is missing, STOP here and do not proceed to the next steps.

### Step 2: Get Defaults

Before prompting the user, retrieve sensible defaults:

```bash
# Get email from git global config for JIRA username default
git_email=$(git config --global user.email 2>/dev/null || echo "")

# Default JIRA URL
default_jira_url="https://badal.atlassian.net"
```

### Step 3: Collect Configuration

If prerequisites are met, use the AskUserQuestion tool to collect all configuration values at once.
Each question should allow direct text input - users can type custom values or select from suggested options.

**IMPORTANT**: Collect ALL values in a SINGLE AskUserQuestion call with multiple questions.
Show defaults clearly in the question text so users can accept them by selecting the default option, or type their own value directly.

Use this format for the AskUserQuestion call:

```
questions:
  - question: "JIRA URL? (default: https://badal.atlassian.net)"
    header: "JIRA URL"
    options:
      - label: "https://badal.atlassian.net"
        description: "Default Badal JIRA instance (Recommended)"
      - label: "Enter URL"
        description: "Type a custom JIRA Cloud URL"
    multiSelect: false

  - question: "Project key? (e.g., PGF, PROJ - the prefix in issue IDs like PROJ-123)"
    header: "Project"
    options:
      - label: "PGF"
        description: "Default project key"
      - label: "Enter key"
        description: "Type your JIRA project key"
    multiSelect: false

  - question: "Label filter? (optional - leave blank to sync all issues)"
    header: "Label"
    options:
      - label: "No filter"
        description: "Sync all issues in the project"
      - label: "Enter label"
        description: "Type a label to filter issues (e.g., DevEx)"
    multiSelect: false

  - question: "JQL filter? (default filters to active sprint/in-progress issues)"
    header: "JQL"
    options:
      - label: "Active issues"
        description: "sprint in openSprints() OR status in ('In Review', 'In Progress')"
      - label: "No filter"
        description: "Sync all issues matching project/label"
      - label: "Enter JQL"
        description: "Type a custom JQL expression"
    multiSelect: false

  - question: "JIRA username/email? (default: {git_email from Step 2})"
    header: "Username"
    options:
      - label: "{git_email}"
        description: "Use email from git config (Recommended)"
      - label: "Enter email"
        description: "Type a different JIRA email/username"
    multiSelect: false
```

**Interpreting responses:**

- If user selects a predefined option (like "https://badal.atlassian.net"), use that value
- If user selects "Enter ..." and types text, use their typed value
- If user selects "No filter" for label, leave it empty
- If user selects "Active issues" for JQL, use: `sprint in openSprints() OR status in ("In Review", "In Progress")`
- If user selects "No filter" for JQL, leave it empty

### Step 4: Initialize beads

Check if beads is initialized in the repository:

```bash
# Check if .beads directory exists
if [[ ! -d ".beads" ]]; then
    echo "Initializing beads..."
    bd init
fi
```

### Step 5: Run beads Doctor

Fix any beads configuration issues:

```bash
bd doctor --fix
```

### Step 6: Configure JIRA Integration

Set the JIRA configuration values:

```bash
# Set JIRA URL
bd config set jira.url "$JIRA_URL"

# Set project key
bd config set jira.project "$PROJECT_KEY"

# Set label (if provided)
if [[ -n "$LABEL" ]]; then
    bd config set jira.label "$LABEL"
fi

# Set JQL filter (if provided)
if [[ -n "$JQL_FILTER" ]]; then
    bd config set jira.jql "$JQL_FILTER"
fi

# Set username
bd config set jira.username "$USERNAME"
```

### Step 7: Verify Configuration

Show the configured values:

```bash
bd config list | grep jira
```

### Step 8: Initial Sync

Perform the first sync from JIRA:

```bash
bd jira sync --pull
```

### Step 9: Show Summary

Display a summary of what was configured and useful next commands:

```
=== Setup Complete ===

Your beads instance is now connected to JIRA.

Configuration:
  URL:      https://company.atlassian.net
  Project:  PROJ
  Label:    DevEx
  JQL:      sprint in openSprints() OR status in ("In Review", "In Progress")
  Username: user@company.com

Useful commands:
  bd jira sync --pull   # Pull issues from JIRA
  bd jira sync --push   # Push issues to JIRA
  bd jira sync          # Bidirectional sync
  bd jira status        # Check sync status
  bd list               # List local issues
```

## Error Handling

### Sync fails with authentication error

```
Sync failed: Authentication error

Please verify:
1. JIRA_API_TOKEN is set correctly
2. jira.username matches your Atlassian account email
3. You have access to the specified project

Run: bd jira status
```

### Project not found

```
Sync failed: Project not found

Please verify:
1. The project key is correct (e.g., "PROJ" not "Project Name")
2. You have access to this project in JIRA

Check your JIRA projects at: https://company.atlassian.net/jira/projects
```
