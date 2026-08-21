#!/bin/bash
#
# claude-rc-manager.sh
# Manages systemd auto-start services for Claude Code Remote Control
#
# Usage:
#   sudo ./claude-rc-manager.sh install <project_dir> [service_name]
#   sudo ./claude-rc-manager.sh uninstall <service_name>
#   ./claude-rc-manager.sh status [service_name]
#   ./claude-rc-manager.sh logs <service_name>
#   ./claude-rc-manager.sh list
#
# Examples:
#   sudo ./claude-rc-manager.sh install /opt/projects/myapp
#   sudo ./claude-rc-manager.sh install /opt/projects/myapp myapp-remote
#   sudo ./claude-rc-manager.sh uninstall claude-remote-control-myapp
#   ./claude-rc-manager.sh status claude-remote-control-myapp
#   ./claude-rc-manager.sh list

set -euo pipefail

SERVICE_PREFIX="claude-remote-control"
SYSTEMD_DIR="/etc/systemd/system"

# ---------- shared helpers ----------

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Error: this operation requires root privileges. Please run with sudo." >&2
    exit 1
  fi
}

find_claude_binary() {
  local target_user="$1"
  local user_home
  user_home=$(getent passwd "$target_user" | cut -d: -f6)

  local candidates=(
    "${user_home}/.local/bin/claude"
    "/usr/local/bin/claude"
    "/usr/bin/claude"
  )

  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done

  # Fallback: run `which` as the target user
  local found
  found=$(sudo -u "$target_user" -H bash -lc 'which claude 2>/dev/null' || true)
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

# Returns 0 if the given project_dir has already been through the workspace
# trust dialog for target_user (per ~/.claude.json), 1 otherwise.
is_workspace_trusted() {
  local target_user="$1"
  local project_dir="$2"
  local user_home="$3"

  local config_file="${user_home}/.claude.json"
  [[ -f "$config_file" ]] || return 1

  local trusted
  trusted=$(jq -r --arg dir "$project_dir" '.projects[$dir].hasTrustDialogAccepted // false' "$config_file" 2>/dev/null || echo "false")
  [[ "$trusted" == "true" ]]
}

list_services() {
  echo "Installed Claude Remote Control services:"
  local found=0
  for f in "${SYSTEMD_DIR}"/${SERVICE_PREFIX}-*.service; do
    [[ -e "$f" ]] || continue
    found=1
    local name
    name=$(basename "$f" .service)
    local active
    active=$(systemctl is-active "$name" 2>/dev/null || echo "unknown")
    local enabled
    enabled=$(systemctl is-enabled "$name" 2>/dev/null || echo "unknown")
    printf "  - %-45s active=%-10s enabled=%s\n" "$name" "$active" "$enabled"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "  (no services found with prefix ${SERVICE_PREFIX}-*)"
  fi
}

# ---------- subcommand: install ----------

cmd_install() {
  require_root

  local project_dir="${1:-}"
  if [[ -z "$project_dir" ]]; then
    echo "Error: project_dir is required. Usage: install <project_dir> [service_name]" >&2
    exit 1
  fi

  if [[ ! -d "$project_dir" ]]; then
    echo "Error: directory does not exist: $project_dir" >&2
    exit 1
  fi
  project_dir="$(cd "$project_dir" && pwd)"

  local svc_short_name="${2:-}"
  if [[ -z "$svc_short_name" ]]; then
    svc_short_name="$(basename "$project_dir")"
  fi
  local service_name="${SERVICE_PREFIX}-${svc_short_name}"
  local unit_file="${SYSTEMD_DIR}/${service_name}.service"

  # Determine which Linux user should run this service: the owner of project_dir
  local run_user
  run_user=$(stat -c '%U' "$project_dir")
  local run_group
  run_group=$(stat -c '%G' "$project_dir")
  local user_home
  user_home=$(getent passwd "$run_user" | cut -d: -f6)

  if [[ -z "$user_home" ]]; then
    echo "Error: could not find home directory for user ${run_user}." >&2
    exit 1
  fi

  echo "Detected run user: ${run_user} (home: ${user_home})"

  # Locate the claude binary
  local claude_bin
  if ! claude_bin=$(find_claude_binary "$run_user"); then
    echo "Error: could not find the claude executable. Please install Claude Code as ${run_user} first" >&2
    echo "  (recommended: curl -fsSL https://claude.ai/install.sh | bash)" >&2
    exit 1
  fi
  echo "Detected claude binary: ${claude_bin}"

  # Check whether login credentials and workspace trust already exist.
  # Trust is stored per project_dir in ~/.claude.json, so a user who has
  # logged in and trusted other projects may still not have trusted THIS one.
  local claude_home="${user_home}/.claude"
  local needs_setup=0
  if [[ ! -d "$claude_home" ]]; then
    echo ""
    echo "Warning: ${claude_home} not found. This user may not have logged in to Claude Code yet."
    needs_setup=1
  elif ! is_workspace_trusted "$run_user" "$project_dir" "$user_home"; then
    echo ""
    echo "Warning: ${project_dir} has not been through the workspace trust dialog yet."
    needs_setup=1
  fi

  if [[ "$needs_setup" -eq 1 ]]; then
    echo "Please run the following one-time setup manually first (this step cannot be automated):"
    echo "  sudo -u ${run_user} -H bash -lc 'cd ${project_dir} && claude'"
    echo "  Inside the interactive session, run /login to authenticate (if needed), then send any"
    echo "  message to trigger and accept the workspace trust prompt."
    echo ""
    read -r -p "Have you already completed login and workspace trust? Continue installing the service? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 1
    fi
    if ! is_workspace_trusted "$run_user" "$project_dir" "$user_home"; then
      echo "Error: ${project_dir} is still not trusted according to ${user_home}/.claude.json." >&2
      echo "The remote-control service will fail to start until this is done. Aborting." >&2
      exit 1
    fi
  fi

  # Build the systemd unit
  local bin_dir
  bin_dir="$(dirname "$claude_bin")"

  cat > "$unit_file" << EOF
[Unit]
Description=Claude Code Remote Control - ${svc_short_name}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${run_user}
Group=${run_group}
WorkingDirectory=${project_dir}
Environment=HOME=${user_home}
Environment=PATH=${bin_dir}:/usr/local/bin:/usr/bin:/bin
ExecStart=${claude_bin} remote-control --name ${svc_short_name} --spawn=same-dir
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  echo "Systemd unit written to: ${unit_file}"

  systemctl daemon-reload
  systemctl enable "${service_name}.service"
  systemctl start "${service_name}.service"

  sleep 2
  echo ""
  echo "===================================================="
  echo "Installation complete: ${service_name}"
  echo "===================================================="
  systemctl status "${service_name}.service" --no-pager || true
  echo ""
  echo "Follow live logs:  sudo journalctl -u ${service_name}.service -f"
  echo "Check status:      $0 status ${service_name}"
  echo "Uninstall:         sudo $0 uninstall ${service_name}"
}

# ---------- subcommand: uninstall ----------

cmd_uninstall() {
  require_root

  local service_name="${1:-}"
  if [[ -z "$service_name" ]]; then
    echo "Error: service_name is required. Usage: uninstall <service_name>" >&2
    echo "Hint: run '$0 list' to see currently installed services." >&2
    exit 1
  fi

  # Allow the prefix to be omitted
  if [[ "$service_name" != ${SERVICE_PREFIX}-* ]]; then
    service_name="${SERVICE_PREFIX}-${service_name}"
  fi

  local unit_file="${SYSTEMD_DIR}/${service_name}.service"

  if [[ ! -f "$unit_file" ]]; then
    echo "Error: unit file not found: ${unit_file}" >&2
    exit 1
  fi

  echo "About to stop and remove service: ${service_name}"
  read -r -p "Are you sure you want to continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi

  systemctl stop "${service_name}.service" 2>/dev/null || true
  systemctl disable "${service_name}.service" 2>/dev/null || true
  rm -f "$unit_file"
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  echo "Removed: ${service_name}"
  echo "Note: login credentials and workspace trust settings under ~/.claude/ are NOT deleted."
  echo "      Clean those up manually in the user's home directory if needed."
}

# ---------- subcommand: status ----------

cmd_status() {
  local service_name="${1:-}"

  if [[ -z "$service_name" ]]; then
    list_services
    return
  fi

  if [[ "$service_name" != ${SERVICE_PREFIX}-* ]]; then
    service_name="${SERVICE_PREFIX}-${service_name}"
  fi

  systemctl status "${service_name}.service" --no-pager
}

# ---------- subcommand: logs ----------

cmd_logs() {
  local service_name="${1:-}"

  if [[ -z "$service_name" ]]; then
    echo "Error: service_name is required. Usage: logs <service_name>" >&2
    echo "Hint: run '$0 list' to see currently installed services." >&2
    exit 1
  fi

  if [[ "$service_name" != ${SERVICE_PREFIX}-* ]]; then
    service_name="${SERVICE_PREFIX}-${service_name}"
  fi

  journalctl -u "${service_name}.service" -f
}

# ---------- main ----------

usage() {
  cat << EOF
Usage: $0 <command> [args]

Commands:
  install <project_dir> [service_name]   Install and start a new Remote Control auto-start service
  uninstall <service_name>               Stop and remove the specified service
  status [service_name]                  Show status of a service; lists all services if omitted
  logs <service_name>                    Follow live logs for the specified service (journalctl -f)
  list                                   List all installed services and their status

Examples:
  sudo $0 install /opt/projects/myapp
  sudo $0 uninstall myapp
  $0 status myapp
  $0 logs myapp
  $0 list
EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    install)   cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    status)    cmd_status "$@" ;;
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
