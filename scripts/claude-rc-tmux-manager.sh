#!/bin/bash
#
# claude-rc-tmux-manager.sh
# Manages tmux sessions running Claude Code Remote Control.
# No root/systemd required -- everything runs as the invoking user.
#
# Usage:
#   ./claude-rc-tmux-manager.sh start <project_dir> [session_name]
#   ./claude-rc-tmux-manager.sh stop <session_name>
#   ./claude-rc-tmux-manager.sh restart <session_name>
#   ./claude-rc-tmux-manager.sh status [session_name]
#   ./claude-rc-tmux-manager.sh attach <session_name>
#   ./claude-rc-tmux-manager.sh logs <session_name> [-f]
#   ./claude-rc-tmux-manager.sh list
#
# Examples:
#   ./claude-rc-tmux-manager.sh start /home/cylin/test/projects/myapp
#   ./claude-rc-tmux-manager.sh start /home/cylin/test/projects/myapp myapp-101
#   ./claude-rc-tmux-manager.sh restart claude-rc-myapp-101
#   ./claude-rc-tmux-manager.sh status
#   ./claude-rc-tmux-manager.sh attach claude-rc-myapp-101
#   ./claude-rc-tmux-manager.sh logs claude-rc-myapp-101 -f

set -euo pipefail

SESSION_PREFIX="claude-rc"
STATE_DIR="${HOME}/.local/state/claude-rc-tmux"
LOG_DIR="${STATE_DIR}/logs"
META_DIR="${STATE_DIR}/meta"
RUN_DIR="${STATE_DIR}/run"

# ---------- shared helpers ----------

require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "Error: tmux is not installed. Please install it first (e.g. apt install tmux)." >&2
    exit 1
  fi
}

normalize_session_name() {
  local name="$1"
  if [[ "$name" != ${SESSION_PREFIX}-* ]]; then
    name="${SESSION_PREFIX}-${name}"
  fi
  echo "$name"
}

find_claude_binary() {
  local candidates=(
    "${HOME}/.local/bin/claude"
    "/usr/local/bin/claude"
    "/usr/bin/claude"
  )

  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done

  local found
  found=$(which claude 2>/dev/null || true)
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

# Returns 0 if project_dir has already been through the workspace trust
# dialog for the current user (per ~/.claude.json), 1 otherwise.
is_workspace_trusted() {
  local project_dir="$1"
  local config_file="${HOME}/.claude.json"
  [[ -f "$config_file" ]] || return 1

  local trusted
  trusted=$(jq -r --arg dir "$project_dir" '.projects[$dir].hasTrustDialogAccepted // false' "$config_file" 2>/dev/null || echo "false")
  [[ "$trusted" == "true" ]]
}

session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

list_services() {
  echo "Running Claude Remote Control tmux sessions:"
  local found=0
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$name" == ${SESSION_PREFIX}-* ]] || continue
    found=1
    local meta_file="${META_DIR}/${name}.meta"
    local project_dir="(unknown)"
    if [[ -f "$meta_file" ]]; then
      project_dir=$(grep -m1 '^project_dir=' "$meta_file" | cut -d= -f2-)
    fi
    printf "  - %-30s dir=%s\n" "$name" "$project_dir"
  done <<< "$sessions"

  # Also surface stopped sessions we still have metadata/logs for.
  if [[ -d "$META_DIR" ]]; then
    for meta_file in "${META_DIR}"/${SESSION_PREFIX}-*.meta; do
      [[ -e "$meta_file" ]] || continue
      local name
      name=$(basename "$meta_file" .meta)
      if ! session_exists "$name"; then
        found=1
        local project_dir
        project_dir=$(grep -m1 '^project_dir=' "$meta_file" | cut -d= -f2-)
        printf "  - %-30s dir=%s (stopped)\n" "$name" "$project_dir"
      fi
    done
  fi

  if [[ "$found" -eq 0 ]]; then
    echo "  (no sessions found with prefix ${SESSION_PREFIX}-*)"
  fi
}

# ---------- subcommand: start ----------

cmd_start() {
  local project_dir="${1:-}"
  if [[ -z "$project_dir" ]]; then
    echo "Error: project_dir is required. Usage: start <project_dir> [session_name]" >&2
    exit 1
  fi
  if [[ ! -d "$project_dir" ]]; then
    echo "Error: directory does not exist: $project_dir" >&2
    exit 1
  fi
  project_dir="$(cd "$project_dir" && pwd)"

  local short_name="${2:-}"
  if [[ -z "$short_name" ]]; then
    short_name="$(basename "$project_dir")"
  fi
  local session_name="${SESSION_PREFIX}-${short_name}"

  if session_exists "$session_name"; then
    echo "Error: tmux session '${session_name}' already exists." >&2
    echo "Hint: '$0 attach ${session_name}' to view it, or '$0 restart ${session_name}' to restart it." >&2
    exit 1
  fi

  local claude_bin
  if ! claude_bin=$(find_claude_binary); then
    echo "Error: could not find the claude executable. Please install Claude Code first" >&2
    echo "  (recommended: curl -fsSL https://claude.ai/install.sh | bash)" >&2
    exit 1
  fi
  echo "Detected claude binary: ${claude_bin}"

  # Check whether login credentials and workspace trust already exist for
  # this specific project_dir (trust is stored per-directory).
  local claude_home="${HOME}/.claude"
  local needs_setup=0
  if [[ ! -d "$claude_home" ]]; then
    echo ""
    echo "Warning: ${claude_home} not found. You may not have logged in to Claude Code yet."
    needs_setup=1
  elif ! is_workspace_trusted "$project_dir"; then
    echo ""
    echo "Warning: ${project_dir} has not been through the workspace trust dialog yet."
    needs_setup=1
  fi

  if [[ "$needs_setup" -eq 1 ]]; then
    echo "Please run the following one-time setup manually first (this step cannot be automated):"
    echo "  cd ${project_dir} && claude"
    echo "  Inside the interactive session, run /login to authenticate (if needed), then send any"
    echo "  message to trigger and accept the workspace trust prompt."
    echo ""
    read -r -p "Have you already completed login and workspace trust? Continue starting the session? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 1
    fi
    if ! is_workspace_trusted "$project_dir"; then
      echo "Error: ${project_dir} is still not trusted according to ${HOME}/.claude.json." >&2
      echo "The remote-control process will fail to start until this is done. Aborting." >&2
      exit 1
    fi
  fi

  mkdir -p "$LOG_DIR" "$META_DIR" "$RUN_DIR"
  local log_file="${LOG_DIR}/${session_name}.log"
  local meta_file="${META_DIR}/${session_name}.meta"
  local run_file="${RUN_DIR}/${session_name}.sh"

  cat > "$run_file" << EOF
#!/bin/bash
cd "${project_dir}" || exit 1
while true; do
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] starting: ${claude_bin} remote-control --name ${short_name} --spawn=same-dir"
  "${claude_bin}" remote-control --name ${short_name} --spawn=same-dir
  ec=\$?
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] remote-control exited (code=\${ec}), restarting in 10s... (Ctrl-C to stop)"
  sleep 10
done
EOF
  chmod +x "$run_file"

  cat > "$meta_file" << EOF
project_dir=${project_dir}
short_name=${short_name}
claude_bin=${claude_bin}
EOF

  tmux new-session -d -s "$session_name" -c "$project_dir" \
    "bash -lc 'exec > >(tee -a \"${log_file}\") 2>&1; exec \"${run_file}\"'"

  echo ""
  echo "===================================================="
  echo "Started: ${session_name}"
  echo "===================================================="
  echo "Attach:   $0 attach ${session_name}"
  echo "Logs:     $0 logs ${session_name} -f"
  echo "Status:   $0 status ${session_name}"
  echo "Stop:     $0 stop ${session_name}"
}

# ---------- subcommand: stop ----------

cmd_stop() {
  local session_name="${1:-}"
  if [[ -z "$session_name" ]]; then
    echo "Error: session_name is required. Usage: stop <session_name>" >&2
    echo "Hint: run '$0 list' to see running sessions." >&2
    exit 1
  fi
  session_name=$(normalize_session_name "$session_name")

  if ! session_exists "$session_name"; then
    echo "Error: tmux session not found: ${session_name}" >&2
    exit 1
  fi

  tmux kill-session -t "$session_name"
  rm -f "${RUN_DIR}/${session_name}.sh"
  echo "Stopped: ${session_name}"
  echo "Note: logs at ${LOG_DIR}/${session_name}.log are kept. Metadata kept for '$0 restart'."
}

# ---------- subcommand: restart ----------

cmd_restart() {
  local session_name="${1:-}"
  if [[ -z "$session_name" ]]; then
    echo "Error: session_name is required. Usage: restart <session_name>" >&2
    exit 1
  fi
  session_name=$(normalize_session_name "$session_name")

  local meta_file="${META_DIR}/${session_name}.meta"
  if [[ ! -f "$meta_file" ]]; then
    echo "Error: no metadata found for ${session_name}. Use '$0 start <project_dir> <short_name>' instead." >&2
    exit 1
  fi

  local project_dir short_name
  project_dir=$(grep -m1 '^project_dir=' "$meta_file" | cut -d= -f2-)
  short_name=$(grep -m1 '^short_name=' "$meta_file" | cut -d= -f2-)

  if session_exists "$session_name"; then
    tmux kill-session -t "$session_name"
    rm -f "${RUN_DIR}/${session_name}.sh"
  fi

  cmd_start "$project_dir" "$short_name"
}

# ---------- subcommand: status ----------

cmd_status() {
  local session_name="${1:-}"

  if [[ -z "$session_name" ]]; then
    list_services
    return
  fi
  session_name=$(normalize_session_name "$session_name")

  if session_exists "$session_name"; then
    echo "Session: ${session_name} (running)"
    tmux list-sessions -F '  #{session_name}: #{session_windows} window(s), created #{session_created_string}' -f "#{==:#{session_name},${session_name}}"
  else
    echo "Session: ${session_name} (not running)"
  fi

  local log_file="${LOG_DIR}/${session_name}.log"
  if [[ -f "$log_file" ]]; then
    echo ""
    echo "-- last 10 log lines (${log_file}) --"
    tail -n 10 "$log_file"
  fi
}

# ---------- subcommand: attach ----------

cmd_attach() {
  local session_name="${1:-}"
  if [[ -z "$session_name" ]]; then
    echo "Error: session_name is required. Usage: attach <session_name>" >&2
    exit 1
  fi
  session_name=$(normalize_session_name "$session_name")

  if ! session_exists "$session_name"; then
    echo "Error: tmux session not found: ${session_name}" >&2
    echo "Hint: run '$0 list' to see running sessions." >&2
    exit 1
  fi

  exec tmux attach-session -t "$session_name"
}

# ---------- subcommand: logs ----------

cmd_logs() {
  local session_name="${1:-}"
  local follow="${2:-}"
  if [[ -z "$session_name" ]]; then
    echo "Error: session_name is required. Usage: logs <session_name> [-f]" >&2
    exit 1
  fi
  session_name=$(normalize_session_name "$session_name")

  local log_file="${LOG_DIR}/${session_name}.log"
  if [[ ! -f "$log_file" ]]; then
    echo "Error: no log file found: ${log_file}" >&2
    exit 1
  fi

  if [[ "$follow" == "-f" ]]; then
    exec tail -f "$log_file"
  else
    cat "$log_file"
  fi
}

# ---------- main ----------

usage() {
  cat << EOF
Usage: $0 <command> [args]

Commands:
  start <project_dir> [session_name]   Start a new tmux session running Remote Control
  stop <session_name>                  Stop the specified session
  restart <session_name>               Stop and restart a previously started session
  status [session_name]                Show status of a session; lists all if omitted
  attach <session_name>                Attach to the live tmux session
  logs <session_name> [-f]             Show captured logs for the session (-f to follow)
  list                                 List all sessions and their status

Examples:
  $0 start /opt/projects/myapp
  $0 start /opt/projects/myapp myapp-101
  $0 restart claude-rc-myapp-101
  $0 status
  $0 attach claude-rc-myapp-101
  $0 logs claude-rc-myapp-101 -f
EOF
}

main() {
  require_tmux

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start)     cmd_start "$@" ;;
    stop)      cmd_stop "$@" ;;
    restart)   cmd_restart "$@" ;;
    status)    cmd_status "$@" ;;
    attach)    cmd_attach "$@" ;;
    logs)      cmd_logs "$@" ;;
    list)      list_services ;;
    -h|--help|help|"") usage ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
