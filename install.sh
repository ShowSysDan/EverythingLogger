#!/usr/bin/env bash
# =============================================================================
# install.sh - FetchLog Service Installer
# =============================================================================
# Usage:
#   sudo ./install.sh            # Full install: setup + install + start
#   sudo ./install.sh setup      # Install Python dependencies system-wide only
#   sudo ./install.sh install    # Create systemd service only (run setup first)
#   sudo ./install.sh start      # Start the service
#   sudo ./install.sh stop       # Stop the service
#   sudo ./install.sh status     # Show service status and recent logs
#   sudo ./install.sh uninstall  # Remove the service (data is preserved)
#
# Environment variable overrides (export before running 'install'):
#   FETCHLOG_UDP_PORT   UDP port for syslog     (default: 5514)
#   FETCHLOG_WEB_PORT   HTTP port for web UI    (default: 8080)
#   FETCHLOG_HOST       Bind address            (default: 0.0.0.0)
#   FETCHLOG_USER       Service user account    (default: fetchlog)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (resolved at script load time)
# ---------------------------------------------------------------------------
SERVICE_NAME="fetchlog"
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ENTRY="${INSTALL_DIR}/app.py"
REQUIREMENTS="${INSTALL_DIR}/requirements.txt"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DATA_DIR="/var/lib/fetchlog"
DB_PATH="${DATA_DIR}/logs.db"

# Overridable via environment
UDP_PORT="${FETCHLOG_UDP_PORT:-5514}"
WEB_PORT="${FETCHLOG_WEB_PORT:-8080}"
HOST="${FETCHLOG_HOST:-0.0.0.0}"
SERVICE_USER="${FETCHLOG_USER:-fetchlog}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*" >&2; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This command must be run as root. Try: sudo $0 $*"
}

# ---------------------------------------------------------------------------
# setup: install Python dependencies system-wide
# ---------------------------------------------------------------------------
cmd_setup() {
    require_root

    echo "========================================"
    echo "  FetchLog - Dependency Setup"
    echo "========================================"

    # Verify Python 3.10+
    info "Checking Python version..."
    local python_bin
    python_bin="$(command -v python3 2>/dev/null)" \
        || die "python3 not found. Install it with: apt-get install python3"

    local version
    version="$("${python_bin}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    local major="${version%%.*}"
    local minor="${version##*.}"

    if [[ "${major}" -lt 3 ]] || { [[ "${major}" -eq 3 ]] && [[ "${minor}" -lt 10 ]]; }; then
        die "Python 3.10+ is required, found ${version}. Please upgrade Python."
    fi
    success "Python ${version} at ${python_bin}"

    # Verify pip is available
    "${python_bin}" -m pip --version >/dev/null 2>&1 \
        || die "pip not found. Install with: apt-get install python3-pip"

    # Attempt pip install; handle PEP 668 externally-managed restriction
    info "Installing dependencies from ${REQUIREMENTS}..."
    local pip_err
    pip_err="$(mktemp)"

    if "${python_bin}" -m pip install -r "${REQUIREMENTS}" --quiet 2>"${pip_err}"; then
        success "Dependencies installed."
    elif grep -q "externally-managed" "${pip_err}" 2>/dev/null; then
        warn "System pip is externally managed (PEP 668). Retrying with --break-system-packages..."
        if "${python_bin}" -m pip install -r "${REQUIREMENTS}" --quiet \
                --break-system-packages 2>"${pip_err}"; then
            success "Dependencies installed with --break-system-packages."
        else
            warn "pip install failed. Output:"
            cat "${pip_err}" >&2
            echo ""
            warn "If you prefer a virtual environment instead, run:"
            warn "  python3 -m venv /opt/fetchlog-venv"
            warn "  /opt/fetchlog-venv/bin/pip install -r ${REQUIREMENTS}"
            warn "Then edit ${SERVICE_FILE} to use /opt/fetchlog-venv/bin/python3"
            rm -f "${pip_err}"
            die "Dependency installation failed."
        fi
    else
        warn "pip install failed. Output:"
        cat "${pip_err}" >&2
        rm -f "${pip_err}"
        die "Dependency installation failed."
    fi
    rm -f "${pip_err}"

    # Make app.py directly executable
    chmod +x "${APP_ENTRY}"
    success "Made ${APP_ENTRY} executable."

    echo ""
    success "Setup complete. Run 'sudo $0 install' to create the service."
}

# ---------------------------------------------------------------------------
# install: create systemd service
# ---------------------------------------------------------------------------
cmd_install() {
    require_root

    echo "========================================"
    echo "  FetchLog - Service Installation"
    echo "========================================"

    # Confirm Python and dependencies are in place
    local python_bin
    python_bin="$(command -v python3 2>/dev/null)" \
        || die "python3 not found. Run 'sudo $0 setup' first."

    info "Verifying installed packages..."
    "${python_bin}" -c "import fastapi, uvicorn, websockets, jinja2, aiofiles, dateutil" \
        2>/dev/null \
        || die "Required packages are missing. Run 'sudo $0 setup' first."
    success "All packages present."

    # Create dedicated system user (no login, no home directory)
    if ! id "${SERVICE_USER}" &>/dev/null; then
        info "Creating system user '${SERVICE_USER}'..."
        useradd --system \
                --no-create-home \
                --shell /usr/sbin/nologin \
                --comment "FetchLog service account" \
                "${SERVICE_USER}"
        success "User '${SERVICE_USER}' created."
    else
        info "User '${SERVICE_USER}' already exists."
    fi

    # Create persistent data directory
    info "Creating data directory ${DATA_DIR}..."
    mkdir -p "${DATA_DIR}"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${DATA_DIR}"
    chmod 750 "${DATA_DIR}"
    success "Data directory ready: ${DATA_DIR}"

    # Grant the service user read access to the application files.
    # (Files remain owned by the deploying user so git pull keeps working.)
    chmod o+rX "${INSTALL_DIR}"
    find "${INSTALL_DIR}" \
        -not -path "${INSTALL_DIR}/.git" \
        -not -path "${INSTALL_DIR}/.git/*" \
        -exec chmod o+r {} \; 2>/dev/null || true

    # Write the systemd unit file
    info "Writing ${SERVICE_FILE}..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=FetchLog Universal Syslog Server & Log Viewer
Documentation=https://github.com/ShowSysDan/FetchLog
After=network.target
Wants=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}

# WorkingDirectory is required: web_server.py uses relative paths
# for static files and Jinja2 templates ("static/" and "templates/")
WorkingDirectory=${INSTALL_DIR}

ExecStart=${python_bin} ${APP_ENTRY} \\
    --udp-port ${UDP_PORT} \\
    --web-port ${WEB_PORT} \\
    --host ${HOST} \\
    --db ${DB_PATH}

Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=fetchlog

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    success "Service file written."

    # Reload systemd and enable the service
    info "Reloading systemd daemon..."
    systemctl daemon-reload

    info "Enabling ${SERVICE_NAME} to start on boot..."
    systemctl enable "${SERVICE_NAME}"

    echo ""
    success "Service installed and enabled."
    info "Configuration baked into service:"
    info "  UDP syslog port : ${UDP_PORT}"
    info "  Web UI port     : ${WEB_PORT}"
    info "  Bind address    : ${HOST}"
    info "  Database        : ${DB_PATH}"
    info "  Running as user : ${SERVICE_USER}"
    echo ""
    info "To change these, edit ${SERVICE_FILE} then run: sudo systemctl daemon-reload"
    echo ""
    success "Run 'sudo $0 start' to launch FetchLog."
}

# ---------------------------------------------------------------------------
# start: start the service and show status
# ---------------------------------------------------------------------------
cmd_start() {
    require_root
    info "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}"
    sleep 1
    systemctl status "${SERVICE_NAME}" --no-pager -l || true
    echo ""
    success "FetchLog is running."
    info "Web UI:  http://localhost:${WEB_PORT}"
    info "Logs:    journalctl -u ${SERVICE_NAME} -f"
}

# ---------------------------------------------------------------------------
# stop: stop the service
# ---------------------------------------------------------------------------
cmd_stop() {
    require_root
    info "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}"
    success "Service stopped."
}

# ---------------------------------------------------------------------------
# status: show service status
# ---------------------------------------------------------------------------
cmd_status() {
    systemctl status "${SERVICE_NAME}" --no-pager -l || true
}

# ---------------------------------------------------------------------------
# uninstall: remove service (preserve data)
# ---------------------------------------------------------------------------
cmd_uninstall() {
    require_root

    echo "========================================"
    echo "  FetchLog - Uninstall Service"
    echo "========================================"
    warn "This removes the systemd service."
    warn "Data at ${DATA_DIR} will NOT be deleted."
    echo ""
    read -rp "Continue? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { info "Uninstall cancelled."; exit 0; }

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "Stopping service..."
        systemctl stop "${SERVICE_NAME}"
    fi

    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        info "Disabling service..."
        systemctl disable "${SERVICE_NAME}"
    fi

    if [[ -f "${SERVICE_FILE}" ]]; then
        info "Removing ${SERVICE_FILE}..."
        rm "${SERVICE_FILE}"
    fi

    systemctl daemon-reload

    echo ""
    success "Service removed."
    info "Data preserved at: ${DATA_DIR}"
    info "To fully clean up:"
    info "  sudo rm -rf ${DATA_DIR}"
    info "  sudo userdel ${SERVICE_USER}"
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  (none)     Full install: setup + install + start"
    echo "  setup      Install Python dependencies system-wide"
    echo "  install    Create and enable systemd service"
    echo "  start      Start the service"
    echo "  stop       Stop the service"
    echo "  status     Show service status"
    echo "  uninstall  Remove the service (preserves database)"
    echo ""
    echo "Environment overrides (set before running 'install'):"
    echo "  FETCHLOG_UDP_PORT   UDP syslog port     (default: 5514)"
    echo "  FETCHLOG_WEB_PORT   Web UI HTTP port    (default: 8080)"
    echo "  FETCHLOG_HOST       Bind address        (default: 0.0.0.0)"
    echo "  FETCHLOG_USER       Service user        (default: fetchlog)"
}

main() {
    local command="${1:-all}"
    case "${command}" in
        setup)     cmd_setup ;;
        install)   cmd_install ;;
        start)     cmd_start ;;
        stop)      cmd_stop ;;
        status)    cmd_status ;;
        uninstall) cmd_uninstall ;;
        all)
            cmd_setup
            echo ""
            cmd_install
            echo ""
            cmd_start
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            warn "Unknown command: ${command}"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
