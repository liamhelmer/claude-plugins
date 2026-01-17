#!/usr/bin/env bash
# Common utility functions for fork-join hooks

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log levels
LOG_LEVEL="${FORK_JOIN_LOG_LEVEL:-INFO}"

# Logging functions
log_debug() {
	if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
		echo -e "${BLUE}[DEBUG]${NC} $*" >&2
	fi
}

log_info() {
	if [[ "$LOG_LEVEL" == "DEBUG" || "$LOG_LEVEL" == "INFO" ]]; then
		echo -e "${GREEN}[INFO]${NC} $*" >&2
	fi
}

log_warn() {
	if [[ "$LOG_LEVEL" != "ERROR" ]]; then
		echo -e "${YELLOW}[WARN]${NC} $*" >&2
	fi
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check if a command exists
command_exists() {
	command -v "$1" >/dev/null 2>&1
}

# Ensure required commands are available
require_commands() {
	local missing=()
	for cmd in "$@"; do
		if ! command_exists "$cmd"; then
			missing+=("$cmd")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		log_error "Missing required commands: ${missing[*]}"
		return 1
	fi
}

# Generate a short unique ID
generate_short_id() {
	if command_exists uuidgen; then
		uuidgen | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]'
	else
		head -c 8 /dev/urandom | xxd -p | head -c 8
	fi
}

# Safe JSON string escaping
json_escape() {
	printf '%s' "$1" | jq -Rs .
}

# Read JSON value from string
json_get() {
	local json="$1"
	local key="$2"
	echo "$json" | jq -r ".$key // empty"
}

# Check if running in CI environment
is_ci() {
	[[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" || -n "${GITLAB_CI:-}" || -n "${JENKINS_URL:-}" ]]
}

# Cleanup function for traps
cleanup() {
	local exit_code=$?
	# Add cleanup logic here
	exit $exit_code
}

# Set up trap for cleanup
setup_cleanup_trap() {
	trap cleanup EXIT INT TERM
}
