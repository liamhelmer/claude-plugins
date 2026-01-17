#!/usr/bin/env bash
#
# End-to-End Test for agent-fork-join plugin
#
# This script:
# 1) Creates a unique test repository using gh in the user's org
# 2) Initializes with CLAUDE.md, AGENTS.md, and the agent-fork-join plugin
# 3) Creates a prompt requiring 5+ concurrent agents
# 4) Spawns a Claude instance to run the prompt
# 5) Verifies branch creation with 5+ commits and a PR
# 6) Optional --clean flag to clean up everything
#
# Usage:
#   ./e2e-test.sh [--clean] [--org ORG_NAME] [--timeout SECONDS]
#
# Requirements:
#   - gh CLI authenticated
#   - claude CLI installed
#   - cargo (for daemon build)
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../../plugins/agent-fork-join" && pwd)"

# Configuration
DEFAULT_ORG="liamhelmer"
DEFAULT_TIMEOUT=600 # 10 minutes
TEST_REPO_PREFIX="fork-join-test"
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
CLEAN_UP=false
ORG_NAME="${DEFAULT_ORG}"
TIMEOUT="${DEFAULT_TIMEOUT}"
REPO_NAME=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
	case $1 in
	--clean)
		CLEAN_UP=true
		shift
		;;
	--org)
		ORG_NAME="$2"
		shift 2
		;;
	--timeout)
		TIMEOUT="$2"
		shift 2
		;;
	--repo)
		REPO_NAME="$2"
		shift 2
		;;
	--verbose | -v)
		VERBOSE=true
		shift
		;;
	--help | -h)
		cat <<EOF
Usage: $0 [OPTIONS]

End-to-end test for the agent-fork-join plugin.

Options:
  --clean           Clean up the test repository after test completes
  --org ORG         GitHub organization/user (default: ${DEFAULT_ORG})
  --timeout SECS    Timeout in seconds (default: ${DEFAULT_TIMEOUT})
  --repo NAME       Use specific repo name instead of generated one
  --verbose, -v     Verbose output
  --help, -h        Show this help message

Examples:
  $0                    # Run test, keep repo
  $0 --clean            # Run test, delete repo after
  $0 --org myorg        # Run test in different org
EOF
		exit 0
		;;
	*)
		log_error "Unknown option: $1"
		exit 1
		;;
	esac
done

# Generate unique repo name if not provided
if [[ -z "${REPO_NAME}" ]]; then
	REPO_NAME="${TEST_REPO_PREFIX}-${TIMESTAMP}"
fi

FULL_REPO="${ORG_NAME}/${REPO_NAME}"
TEST_DIR=""

# Cleanup function
cleanup() {
	local exit_code=$?

	log_info "Cleaning up..."

	# Stop any running daemon
	if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
		kill "${DAEMON_PID}" 2>/dev/null || true
	fi

	# Remove local test directory
	if [[ -n "${TEST_DIR}" && -d "${TEST_DIR}" ]]; then
		rm -rf "${TEST_DIR}"
	fi

	# Delete remote repo if --clean was specified
	if [[ "${CLEAN_UP}" == "true" && -n "${REPO_NAME}" ]]; then
		log_info "Deleting remote repository ${FULL_REPO}..."
		gh repo delete "${FULL_REPO}" --yes 2>/dev/null || true
	fi

	exit $exit_code
}

trap cleanup EXIT

# Check prerequisites
check_prerequisites() {
	log_info "Checking prerequisites..."

	local missing=()

	command -v gh >/dev/null 2>&1 || missing+=("gh")
	command -v claude >/dev/null 2>&1 || missing+=("claude")
	command -v git >/dev/null 2>&1 || missing+=("git")
	command -v cargo >/dev/null 2>&1 || missing+=("cargo")
	command -v jq >/dev/null 2>&1 || missing+=("jq")

	if [[ ${#missing[@]} -gt 0 ]]; then
		log_error "Missing required tools: ${missing[*]}"
		exit 1
	fi

	# Check gh auth
	if ! gh auth status >/dev/null 2>&1; then
		log_error "gh CLI not authenticated. Run: gh auth login"
		exit 1
	fi

	# Check if plugin daemon is built
	if [[ ! -f "${PLUGIN_ROOT}/daemon/target/release/merge-daemon" ]]; then
		log_warn "Merge daemon not built. Building now..."
		(cd "${PLUGIN_ROOT}/daemon" && cargo build --release)
	fi

	log_success "All prerequisites satisfied"
}

# Create test repository
create_test_repo() {
	log_info "Creating test repository: ${FULL_REPO}"

	# Create the repo on GitHub
	gh repo create "${FULL_REPO}" \
		--public \
		--description "E2E test repository for agent-fork-join plugin" \
		--clone=false

	log_success "Created remote repository: ${FULL_REPO}"

	# Create local directory and initialize
	TEST_DIR="$(mktemp -d)"
	cd "${TEST_DIR}"

	git init
	git remote add origin "https://github.com/${FULL_REPO}.git"

	# Create initial files
	create_claude_md
	create_agents_md
	create_package_json
	setup_plugin

	# Initial commit
	git add .
	git commit -m "Initial commit: Set up test repository with agent-fork-join plugin"
	git branch -M main
	git push -u origin main

	log_success "Repository initialized and pushed"
}

# Create CLAUDE.md with fork-join plugin configuration
create_claude_md() {
	cat >CLAUDE.md <<'EOF'
# Test Project - Agent Fork-Join E2E Test

This is a test project for validating the agent-fork-join plugin.

## Project Structure

This project will be built by multiple concurrent agents, each creating a separate module.

## Plugin Configuration

The agent-fork-join plugin is configured with:
- Max concurrent agents: 8
- Merge strategy: rebase
- Feature branch prefix: feature/
- Agent branch prefix: agent/

## Development Rules

1. Each agent creates files in its assigned directory only
2. All code must include a file header comment
3. No agent should modify another agent's files
4. Tests should be created alongside implementation files

## Agent Assignment

When spawning agents for this project:
- Agent 1: Creates `/src/auth/` module (authentication)
- Agent 2: Creates `/src/api/` module (API endpoints)
- Agent 3: Creates `/src/db/` module (database layer)
- Agent 4: Creates `/src/utils/` module (utility functions)
- Agent 5: Creates `/src/config/` module (configuration management)
EOF
}

# Create AGENTS.md with agent definitions
create_agents_md() {
	cat >AGENTS.md <<'EOF'
# Agent Definitions

## Concurrent Agents for Module Development

This project uses 5 specialized agents working in parallel to build different modules.

### Agent 1: AuthAgent
- **Role**: Authentication module developer
- **Directory**: `/src/auth/`
- **Files to create**:
  - `index.ts` - Main authentication exports
  - `jwt.ts` - JWT token handling
  - `middleware.ts` - Auth middleware

### Agent 2: APIAgent
- **Role**: API endpoint developer
- **Directory**: `/src/api/`
- **Files to create**:
  - `index.ts` - API router setup
  - `users.ts` - User endpoints
  - `health.ts` - Health check endpoint

### Agent 3: DBAgent
- **Role**: Database layer developer
- **Directory**: `/src/db/`
- **Files to create**:
  - `index.ts` - Database connection
  - `models.ts` - Data models
  - `migrations.ts` - Migration helpers

### Agent 4: UtilsAgent
- **Role**: Utility functions developer
- **Directory**: `/src/utils/`
- **Files to create**:
  - `index.ts` - Utility exports
  - `logger.ts` - Logging utility
  - `validators.ts` - Input validators

### Agent 5: ConfigAgent
- **Role**: Configuration management developer
- **Directory**: `/src/config/`
- **Files to create**:
  - `index.ts` - Config exports
  - `env.ts` - Environment handling
  - `constants.ts` - Application constants

## Coordination

All agents should:
1. Work only in their assigned directories
2. Create all listed files
3. Include proper TypeScript types
4. Add file header comments with agent name
EOF
}

# Create package.json for validation
create_package_json() {
	cat >package.json <<'EOF'
{
  "name": "fork-join-test-project",
  "version": "1.0.0",
  "description": "E2E test project for agent-fork-join plugin",
  "main": "src/index.ts",
  "scripts": {
    "test": "echo 'Tests passed'",
    "lint": "echo 'Lint passed'",
    "typecheck": "echo 'Typecheck passed'"
  },
  "devDependencies": {}
}
EOF
}

# Set up the agent-fork-join plugin
setup_plugin() {
	mkdir -p .claude/plugins/agent-fork-join

	# Copy plugin files
	cp "${PLUGIN_ROOT}/plugin.json" .claude/plugins/agent-fork-join/
	cp "${PLUGIN_ROOT}/SKILL.md" .claude/plugins/agent-fork-join/
	cp -r "${PLUGIN_ROOT}/hooks" .claude/plugins/agent-fork-join/
	cp -r "${PLUGIN_ROOT}/scripts" .claude/plugins/agent-fork-join/

	# Copy daemon binary
	mkdir -p .claude/plugins/agent-fork-join/daemon/target/release
	cp "${PLUGIN_ROOT}/daemon/target/release/merge-daemon" \
		.claude/plugins/agent-fork-join/daemon/target/release/

	# Make scripts executable
	chmod +x .claude/plugins/agent-fork-join/hooks/*.sh
	chmod +x .claude/plugins/agent-fork-join/scripts/*.sh
	chmod +x .claude/plugins/agent-fork-join/daemon/target/release/merge-daemon

	# Create hook library directory
	mkdir -p .claude/plugins/agent-fork-join/hooks/lib
	if [[ -d "${PLUGIN_ROOT}/hooks/lib" ]]; then
		cp -r "${PLUGIN_ROOT}/hooks/lib"/* .claude/plugins/agent-fork-join/hooks/lib/
	fi

	# Configure hooks in .claude/settings.json
	mkdir -p .claude
	cat >.claude/settings.json <<'EOF'
{
  "plugins": {
    "enabled": ["agent-fork-join"]
  },
  "hooks": {
    "UserPromptSubmit": [".claude/plugins/agent-fork-join/hooks/on-prompt-submit.sh"],
    "AgentSpawn": [".claude/plugins/agent-fork-join/hooks/on-agent-spawn.sh"],
    "AgentComplete": [".claude/plugins/agent-fork-join/hooks/on-agent-complete.sh"]
  }
}
EOF

	log_success "Plugin installed to .claude/plugins/agent-fork-join"
}

# Create the test prompt that spawns 5 agents
create_test_prompt() {
	cat <<'EOF'
Build out the full project structure as defined in AGENTS.md.

You MUST spawn exactly 5 concurrent agents to work in parallel:

1. Spawn AuthAgent to create all files in /src/auth/
2. Spawn APIAgent to create all files in /src/api/
3. Spawn DBAgent to create all files in /src/db/
4. Spawn UtilsAgent to create all files in /src/utils/
5. Spawn ConfigAgent to create all files in /src/config/

Each agent should:
- Create their assigned directory
- Create all 3 files listed for their module
- Include proper TypeScript code with types
- Add a file header comment identifying which agent created it

All agents should work simultaneously. Do NOT wait for one to complete before starting another.

After all agents complete, verify each created their files by listing the /src directory structure.
EOF
}

# Run Claude with the test prompt
run_claude_test() {
	log_info "Running Claude with test prompt..."

	local prompt
	prompt="$(create_test_prompt)"

	local log_file="${LOG_DIR}/${REPO_NAME}-claude.log"
	mkdir -p "${LOG_DIR}"

	# Run claude with timeout
	local claude_exit=0
	timeout "${TIMEOUT}" claude --print "${prompt}" >"${log_file}" 2>&1 || claude_exit=$?

	if [[ $claude_exit -eq 124 ]]; then
		log_error "Claude timed out after ${TIMEOUT} seconds"
		return 1
	elif [[ $claude_exit -ne 0 ]]; then
		log_error "Claude exited with code ${claude_exit}"
		if [[ "${VERBOSE}" == "true" ]]; then
			cat "${log_file}"
		fi
		return 1
	fi

	log_success "Claude completed successfully"

	if [[ "${VERBOSE}" == "true" ]]; then
		log_info "Claude output:"
		cat "${log_file}"
	fi
}

# Verify test results
verify_results() {
	log_info "Verifying test results..."

	local errors=()

	# Check for feature branch
	log_info "Checking for feature branches..."
	local branches
	branches=$(git branch -a 2>/dev/null || echo "")

	local feature_branch=""
	while IFS= read -r branch; do
		if [[ "${branch}" =~ feature/ ]]; then
			feature_branch="${branch}"
			break
		fi
	done <<<"${branches}"

	if [[ -z "${feature_branch}" ]]; then
		log_warn "No feature branch found locally, checking remote..."
		branches=$(git ls-remote --heads origin 2>/dev/null || echo "")
		while IFS= read -r line; do
			if [[ "${line}" =~ refs/heads/(feature/.*) ]]; then
				feature_branch="${BASH_REMATCH[1]}"
				break
			fi
		done <<<"${branches}"
	fi

	if [[ -z "${feature_branch}" ]]; then
		errors+=("No feature branch created")
	else
		log_success "Feature branch found: ${feature_branch}"
	fi

	# Check commit count (looking for 5+ agent commits)
	log_info "Checking commit count..."
	local commit_count
	if [[ -n "${feature_branch}" ]]; then
		# Fetch the branch first
		git fetch origin "${feature_branch}" 2>/dev/null || true
		commit_count=$(git rev-list --count "origin/${feature_branch}" 2>/dev/null || echo "0")
	else
		commit_count=$(git rev-list --count HEAD 2>/dev/null || echo "1")
	fi

	if [[ "${commit_count}" -lt 5 ]]; then
		errors+=("Expected at least 5 commits, found ${commit_count}")
	else
		log_success "Commit count: ${commit_count} (meets minimum of 5)"
	fi

	# Check for PR
	log_info "Checking for pull request..."
	local pr_list
	pr_list=$(gh pr list --repo "${FULL_REPO}" --json number,title,state 2>/dev/null || echo "[]")
	local pr_count
	pr_count=$(echo "${pr_list}" | jq 'length')

	if [[ "${pr_count}" -eq 0 ]]; then
		errors+=("No pull request created")
	else
		local pr_info
		pr_info=$(echo "${pr_list}" | jq -r '.[0] | "#\(.number): \(.title) [\(.state)]"')
		log_success "Pull request found: ${pr_info}"
	fi

	# Check for created directories
	log_info "Checking for created directories..."
	local expected_dirs=("src/auth" "src/api" "src/db" "src/utils" "src/config")
	local missing_dirs=()

	for dir in "${expected_dirs[@]}"; do
		if [[ ! -d "${dir}" ]]; then
			# Check if it exists on remote
			if git ls-tree --name-only -r "origin/${feature_branch:-main}" 2>/dev/null | grep -q "^${dir}/"; then
				log_success "Directory ${dir}/ exists (on remote)"
			else
				missing_dirs+=("${dir}")
			fi
		else
			log_success "Directory ${dir}/ exists"
		fi
	done

	if [[ ${#missing_dirs[@]} -gt 0 ]]; then
		errors+=("Missing directories: ${missing_dirs[*]}")
	fi

	# Print summary
	echo ""
	echo "========================================="
	echo "           TEST RESULTS SUMMARY"
	echo "========================================="
	echo ""
	echo "Repository:     ${FULL_REPO}"
	echo "Feature Branch: ${feature_branch:-N/A}"
	echo "Commits:        ${commit_count}"
	echo "Pull Requests:  ${pr_count}"
	echo ""

	if [[ ${#errors[@]} -eq 0 ]]; then
		log_success "All verifications passed!"
		echo ""
		echo "Repository URL: https://github.com/${FULL_REPO}"
		if [[ "${pr_count}" -gt 0 ]]; then
			local pr_number
			pr_number=$(echo "${pr_list}" | jq -r '.[0].number')
			echo "Pull Request:   https://github.com/${FULL_REPO}/pull/${pr_number}"
		fi
		return 0
	else
		log_error "Test failed with ${#errors[@]} error(s):"
		for err in "${errors[@]}"; do
			echo "  - ${err}"
		done
		return 1
	fi
}

# Main test execution
main() {
	echo ""
	echo "========================================="
	echo "   Agent Fork-Join E2E Test"
	echo "========================================="
	echo ""
	echo "Repository: ${FULL_REPO}"
	echo "Clean up:   ${CLEAN_UP}"
	echo "Timeout:    ${TIMEOUT}s"
	echo ""

	check_prerequisites
	create_test_repo

	cd "${TEST_DIR}"

	run_claude_test

	verify_results

	local result=$?

	if [[ $result -eq 0 ]]; then
		echo ""
		log_success "E2E test completed successfully!"
		if [[ "${CLEAN_UP}" != "true" ]]; then
			echo ""
			echo "The test repository has been kept for inspection."
			echo "Run with --clean to automatically delete it after testing."
		fi
	else
		echo ""
		log_error "E2E test failed!"
		echo "Check logs at: ${LOG_DIR}/${REPO_NAME}-claude.log"
	fi

	return $result
}

main
