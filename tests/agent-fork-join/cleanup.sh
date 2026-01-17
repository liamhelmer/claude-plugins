#!/usr/bin/env bash
#
# Cleanup script for agent-fork-join E2E tests
#
# Deletes test repositories created by the E2E test suite.
#
# Usage:
#   ./cleanup.sh [REPO_NAME]           # Delete specific repo
#   ./cleanup.sh --all                 # Delete all test repos
#   ./cleanup.sh --list                # List test repos
#   ./cleanup.sh --dry-run --all       # Show what would be deleted
#

set -euo pipefail

# Configuration
DEFAULT_ORG="liamhelmer"
TEST_REPO_PREFIX="fork-join-test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
ORG_NAME="${DEFAULT_ORG}"
DRY_RUN=false
DELETE_ALL=false
LIST_ONLY=false
REPO_NAME=""

while [[ $# -gt 0 ]]; do
	case $1 in
	--org)
		ORG_NAME="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=true
		shift
		;;
	--all)
		DELETE_ALL=true
		shift
		;;
	--list)
		LIST_ONLY=true
		shift
		;;
	--help | -h)
		cat <<EOF
Usage: $0 [OPTIONS] [REPO_NAME]

Clean up test repositories created by E2E tests.

Options:
  --all              Delete all test repositories (${TEST_REPO_PREFIX}-*)
  --list             List test repositories without deleting
  --dry-run          Show what would be deleted without actually deleting
  --org ORG          GitHub organization/user (default: ${DEFAULT_ORG})
  --help, -h         Show this help message

Examples:
  $0 fork-join-test-20240115-123456   # Delete specific repo
  $0 --list                            # List all test repos
  $0 --all                             # Delete all test repos
  $0 --dry-run --all                   # Preview deletion
EOF
		exit 0
		;;
	-*)
		log_error "Unknown option: $1"
		exit 1
		;;
	*)
		REPO_NAME="$1"
		shift
		;;
	esac
done

# List test repositories
list_test_repos() {
	gh repo list "${ORG_NAME}" --json name,createdAt,description --limit 100 |
		jq -r --arg prefix "${TEST_REPO_PREFIX}" '.[] | select(.name | startswith($prefix)) | "\(.name)\t\(.createdAt)\t\(.description // "N/A")"'
}

# Delete a single repository
delete_repo() {
	local repo="$1"
	local full_repo="${ORG_NAME}/${repo}"

	if [[ "${DRY_RUN}" == "true" ]]; then
		log_info "[DRY RUN] Would delete: ${full_repo}"
		return 0
	fi

	log_info "Deleting repository: ${full_repo}"
	if gh repo delete "${full_repo}" --yes 2>/dev/null; then
		log_success "Deleted: ${full_repo}"
	else
		log_error "Failed to delete: ${full_repo}"
		return 1
	fi
}

# Main
main() {
	# Check gh auth
	if ! gh auth status >/dev/null 2>&1; then
		log_error "gh CLI not authenticated. Run: gh auth login"
		exit 1
	fi

	if [[ "${LIST_ONLY}" == "true" ]]; then
		echo "Test repositories in ${ORG_NAME}:"
		echo ""
		echo -e "NAME\tCREATED\tDESCRIPTION"
		echo "--------------------------------------------"
		list_test_repos
		exit 0
	fi

	if [[ "${DELETE_ALL}" == "true" ]]; then
		log_info "Finding all test repositories..."
		local repos
		repos=$(list_test_repos | cut -f1)

		if [[ -z "${repos}" ]]; then
			log_info "No test repositories found"
			exit 0
		fi

		local count
		count=$(echo "${repos}" | wc -l | tr -d ' ')
		log_warn "Found ${count} test repository/repositories to delete"

		if [[ "${DRY_RUN}" != "true" ]]; then
			echo ""
			echo "This will delete the following repositories:"
			echo "${repos}" | while read -r repo; do
				echo "  - ${ORG_NAME}/${repo}"
			done
			echo ""
			read -p "Are you sure? (y/N) " -n 1 -r
			echo ""
			if [[ ! $REPLY =~ ^[Yy]$ ]]; then
				log_info "Aborted"
				exit 0
			fi
		fi

		echo "${repos}" | while read -r repo; do
			delete_repo "${repo}"
		done

		log_success "Cleanup complete"

	elif [[ -n "${REPO_NAME}" ]]; then
		delete_repo "${REPO_NAME}"
	else
		log_error "Specify a repository name or use --all"
		exit 1
	fi
}

main
