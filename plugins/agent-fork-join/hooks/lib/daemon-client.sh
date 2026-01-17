#!/usr/bin/env bash
# Merge daemon IPC client functions

# Default socket path
DAEMON_SOCKET="${FORK_JOIN_DAEMON_SOCKET:-/tmp/merge-daemon.sock}"
DAEMON_BIN="${FORK_JOIN_DAEMON_BIN:-merge-daemon}"

# Check if daemon is running
daemon_is_running() {
	[[ -S "$DAEMON_SOCKET" ]] && daemon_send '{"type":"STATUS"}' >/dev/null 2>&1
}

# Send a message to the daemon and get response
daemon_send() {
	local message="$1"
	local timeout="${2:-5}"

	if [[ ! -S "$DAEMON_SOCKET" ]]; then
		echo '{"status":"ERROR","error":"Daemon socket not found"}'
		return 1
	fi

	# Use netcat to send message and receive response
	if command -v nc >/dev/null 2>&1; then
		echo "$message" | nc -U -w "$timeout" "$DAEMON_SOCKET" 2>/dev/null
	elif command -v socat >/dev/null 2>&1; then
		echo "$message" | socat -t "$timeout" - "UNIX-CONNECT:$DAEMON_SOCKET" 2>/dev/null
	else
		log_error "No suitable socket client found (nc or socat required)"
		echo '{"status":"ERROR","error":"No socket client available"}'
		return 1
	fi
}

# Start the daemon
start_daemon() {
	local repo_path="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
	local state_dir="${FORK_JOIN_STATE_DIR:-.fork-join}"
	local db_path="${state_dir}/state.db"

	# Create state directory
	mkdir -p "$state_dir"

	# Find daemon binary
	local daemon_path=""

	# Check if it's in the plugin directory
	local plugin_dir
	plugin_dir="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"

	if [[ -x "${plugin_dir}/daemon/target/release/${DAEMON_BIN}" ]]; then
		daemon_path="${plugin_dir}/daemon/target/release/${DAEMON_BIN}"
	elif [[ -x "${plugin_dir}/daemon/target/debug/${DAEMON_BIN}" ]]; then
		daemon_path="${plugin_dir}/daemon/target/debug/${DAEMON_BIN}"
	elif command -v "$DAEMON_BIN" >/dev/null 2>&1; then
		daemon_path="$DAEMON_BIN"
	fi

	if [[ -z "$daemon_path" ]]; then
		log_error "Merge daemon binary not found. Please build it first:"
		log_error "  cd ${plugin_dir}/daemon && cargo build --release"
		return 1
	fi

	# Start daemon in background
	nohup "$daemon_path" \
		--repo "$repo_path" \
		--socket "$DAEMON_SOCKET" \
		--db "$db_path" \
		--foreground \
		>"${state_dir}/daemon.log" 2>&1 &

	local daemon_pid=$!
	echo "$daemon_pid" >"${state_dir}/daemon.pid"

	log_info "Started daemon with PID: $daemon_pid"
}

# Stop the daemon
stop_daemon() {
	local state_dir="${FORK_JOIN_STATE_DIR:-.fork-join}"
	local pid_file="${state_dir}/daemon.pid"

	# Try graceful shutdown first
	if daemon_is_running; then
		daemon_send '{"type":"SHUTDOWN"}' >/dev/null 2>&1 || true
		sleep 1
	fi

	# Kill by PID if still running
	if [[ -f "$pid_file" ]]; then
		local pid
		pid="$(cat "$pid_file")"
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			sleep 1
			# Force kill if still running
			kill -9 "$pid" 2>/dev/null || true
		fi
		rm -f "$pid_file"
	fi

	# Remove socket file
	rm -f "$DAEMON_SOCKET"

	log_info "Daemon stopped"
}

# Get daemon status
daemon_status() {
	if ! daemon_is_running; then
		echo '{"running":false}'
		return 1
	fi

	local status
	status="$(daemon_send '{"type":"STATUS"}')"
	echo "$status"
}

# Enqueue a branch for merge
daemon_enqueue() {
	local agent_id="$1"
	local session_id="$2"
	local branch="$3"
	local worktree="$4"
	local target_branch="$5"

	daemon_send "$(
		cat <<EOF
{
    "type": "ENQUEUE",
    "agent_id": "$agent_id",
    "session_id": "$session_id",
    "branch": "$branch",
    "worktree": "$worktree",
    "target_branch": "$target_branch"
}
EOF
	)"
}

# Dequeue an agent
daemon_dequeue() {
	local agent_id="$1"
	daemon_send '{"type":"DEQUEUE","agent_id":"'"$agent_id"'"}'
}

# Get conflicts for an agent
daemon_get_conflicts() {
	local agent_id="$1"
	daemon_send '{"type":"CONFLICTS","agent_id":"'"$agent_id"'"}'
}

# Retry a failed merge
daemon_retry() {
	local agent_id="$1"
	daemon_send '{"type":"RETRY","agent_id":"'"$agent_id"'"}'
}

# Wait for merge result
daemon_wait() {
	local agent_id="$1"
	local timeout="${2:-300}"
	daemon_send '{"type":"WAIT","agent_id":"'"$agent_id"'"}' "$timeout"
}
