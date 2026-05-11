#!/usr/bin/env bash
# ---------------------------------------------------------------------
# first_boot.sh - First-Boot Setup for Inventory Client Stations
#
# Runs exactly once on a freshly flashed Pi via inventory-setup.service.
# Reads secrets from /boot/firmware/provision.conf, installs the fleet
# deploy key, clones the repo, runs full provisioning, and registers
# with the server. On success, zeroes sensitive fields and removes the
# first-boot flag so the service never runs again.
#
# Baked into the OS image at: /opt/inventory/first_boot.sh
# Managed by: inventory-setup.service (also baked into image)
# Flag file: /etc/inventory/first-boot-pending
#
# If any step fails, the flag file is left in place so the service
# retries on the next boot. Secrets are only zeroed on full success.
#
# This file is bundled with inventory-finder-image-creator and also kept at
# client/scripts/first_boot.sh in the private inventory-finder repo.
# The image build process copies it to /opt/inventory/ on the Pi.
# ---------------------------------------------------------------------

set -uo pipefail

# =====================================================================
# CONSTANTS
# =====================================================================

FLAG_FILE="/etc/inventory/first-boot-pending"
PROVISION_CONF="/boot/firmware/provision.conf"
# When run via `sudo bash`, $SUDO_USER is the invoking user (rpi5).
# When run by systemd with User=rpi5, $USER is rpi5. Fall back to rpi5.
# PI_USER is injected by inventory-setup.service via Environment=PI_USER=.
# The SUDO_USER fallback covers manual `sudo bash` invocations.
# $USER is intentionally NOT used as a fallback: when systemd runs this as
# root it sets USER=root, which would cause all paths to resolve under /root.
PI_USER="${PI_USER:-${SUDO_USER:-rpi5}}"
PI_HOME="$(getent passwd "$PI_USER" | cut -d: -f6)"
PI_HOME="${PI_HOME:-/home/${PI_USER}}"
# Export so child processes (provision.sh, register_client.sh) inherit the
# correct values rather than re-deriving from the root environment.
export PI_USER PI_HOME
# Redirect HOME so user-scoped tools (uv, pip) install under PI_HOME
# rather than /root when this script runs as root.
if [ "$(id -u)" = "0" ] && [ "$PI_USER" != "root" ]; then
    export HOME="$PI_HOME"
fi
LOG_FILE="${PI_HOME}/first-boot.log"
REPO_DIR="${PI_HOME}/inventory-finder"
CLIENT_DIR="${REPO_DIR}/client"
GITHUB_REPO="git@github.com:NRay7882/inventory-finder.git"
DEPLOY_KEY_FILE="${PI_HOME}/.ssh/inventory_deploy"
SSH_CONFIG="${PI_HOME}/.ssh/config"
SERVICE_NAME="inventory-setup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# =====================================================================
# LOGGING
# =====================================================================

log()  { echo "$@" | tee -a "$LOG_FILE"; }
ok()   { log -e "  ${GREEN}✓ $*${NC}"; }
warn() { log -e "  ${YELLOW}⚠ $*${NC}"; }
fail() { log -e "  ${RED}✗ $*${NC}"; }
info() { log -e "  ${GRAY}→ $*${NC}"; }

abort() {
    fail "$1"
    log ""
    log -e "${RED}First-boot setup failed. Will retry on next boot.${NC}"
    log -e "${GRAY}Review: ${LOG_FILE}${NC}"
    exit 1
}

fix_owner() {
    [ "$(id -u)" = "0" ] && [ "$PI_USER" != "root" ] || return 0
    chown -R "${PI_USER}:${PI_USER}" "$@" 2>/dev/null || true
}

# =====================================================================
# FLAG FILE CHECK - exit immediately if not a first boot
# =====================================================================

if [ ! -f "$FLAG_FILE" ]; then
    exit 0
fi

# =====================================================================
# BEGIN FIRST-BOOT SETUP
# =====================================================================

echo "=== First-boot setup: $(date -Iseconds) ===" > "$LOG_FILE"
fix_owner "$LOG_FILE"

log ""
log -e "${CYAN}==================================================${NC}"
log -e "${CYAN}  Inventory Client - First Boot Setup${NC}"
log -e "${CYAN}==================================================${NC}"

# Show hardware info
if [ -f /proc/device-tree/model ]; then
    pi_model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
    log -e "  ${GRAY}Hardware: ${pi_model}${NC}"
fi
log -e "  ${GRAY}User: ${PI_USER} | Host: $(hostname)${NC}"
log -e "  ${GRAY}Log: ${LOG_FILE}${NC}"

# =====================================================================
# STEP 1: Read provision.conf
# =====================================================================

log ""
log -e "${CYAN}[1/7] Reading provision.conf${NC}"

if [ ! -f "$PROVISION_CONF" ]; then
    abort "provision.conf not found at ${PROVISION_CONF}. Place it on the boot partition before first boot."
fi

# Source the config (simple KEY=VALUE format)
set -a
# shellcheck source=/dev/null
source "$PROVISION_CONF"
set +a

REGISTRATION_SECRET="${REGISTRATION_SECRET:-}"
SERVER_URL="${SERVER_URL:-}"
DEPLOY_KEY_B64="${DEPLOY_KEY_B64:-}"
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"

missing=()
[ -z "$REGISTRATION_SECRET" ] && missing+=("REGISTRATION_SECRET")
[ -z "$SERVER_URL" ]          && missing+=("SERVER_URL")
[ -z "$DEPLOY_KEY_B64" ]      && missing+=("DEPLOY_KEY_B64")

if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing required fields in provision.conf:"
    for field in "${missing[@]}"; do
        fail "  ${field}"
    done
    abort "Fill in all required fields and reboot."
fi

ok "Required fields present: REGISTRATION_SECRET, SERVER_URL, DEPLOY_KEY_B64"
info "Server: ${SERVER_URL}"
if [ -n "$ADMIN_SSH_KEY" ]; then
    info "Admin SSH key provided - will configure authorized_keys"
else
    warn "No ADMIN_SSH_KEY in provision.conf - password auth will remain active"
fi

# =====================================================================
# STEP 2: WiFi setup (optional - only if WIFI_SSID is provided)
# =====================================================================

log ""
log -e "${CYAN}[2/7] Network connectivity${NC}"

WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
STATIC_IP="${STATIC_IP:-}"
STATIC_GATEWAY="${STATIC_GATEWAY:-}"
STATIC_PREFIX="${STATIC_PREFIX:-24}"
STATIC_DNS="${STATIC_DNS:-8.8.8.8,1.1.1.1}"

# Helper: apply static IP to a NetworkManager connection
apply_static_ip() {
    local conn_name="$1"
    if [ -n "$STATIC_IP" ] && [ -n "$STATIC_GATEWAY" ]; then
        info "Applying static IP: ${STATIC_IP}/${STATIC_PREFIX} via ${STATIC_GATEWAY}"
        sudo nmcli connection modify "$conn_name" \
            ipv4.method manual \
            ipv4.addresses "${STATIC_IP}/${STATIC_PREFIX}" \
            ipv4.gateway "$STATIC_GATEWAY" \
            ipv4.dns "$STATIC_DNS" 2>/dev/null
        ok "Static IP configured on ${conn_name}"
        return 0
    fi
    return 1
}

if [ -n "$WIFI_SSID" ]; then
    info "WiFi SSID provided: ${WIFI_SSID}"

    # Set regulatory country - raspi-config writes it persistently so the
    # radio becomes available after unblock. iw reg set alone is session-only
    # and does not unblock an adapter that is in the "unavailable" NM state.
    if [ -n "$WIFI_COUNTRY" ]; then
        sudo raspi-config nonint do_wifi_country "$WIFI_COUNTRY" 2>/dev/null || true
        sudo iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
        ok "WiFi country set to ${WIFI_COUNTRY}"
    fi

    # Unblock WiFi radio
    sudo rfkill unblock wifi 2>/dev/null || true
    sudo rfkill unblock all 2>/dev/null || true

    # Bring the interface up so NM transitions it out of "unavailable"
    sudo ip link set wlan0 up 2>/dev/null || true

    # Wait up to 20 seconds for wlan0 to leave the "unavailable" state
    info "Waiting for wlan0 to become available..."
    wlan_ready=false
    for _i in $(seq 1 20); do
        nm_state=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: '/^wlan0:/ {print $2}')
        if [ "$nm_state" != "unavailable" ] && [ -n "$nm_state" ]; then
            wlan_ready=true
            ok "wlan0 is ${nm_state}"
            break
        fi
        sleep 1
    done

    if [ "$wlan_ready" = false ]; then
        warn "wlan0 still unavailable after 20s - WiFi connection will likely fail"
    fi

    # Check if already connected via WiFi
    if nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q "wifi:connected"; then
        ok "WiFi already connected"
    else
        info "Connecting to WiFi..."
        wifi_conn_name="inventory-wifi"

        # Remove any stale connection with this name
        sudo nmcli connection delete "$wifi_conn_name" 2>/dev/null || true

        if [ -n "$STATIC_IP" ] && [ -n "$STATIC_GATEWAY" ]; then
            # Create connection with static IP in one shot
            sudo nmcli connection add \
                type wifi ifname wlan0 con-name "$wifi_conn_name" \
                ssid "$WIFI_SSID" \
                wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASSWORD" \
                ipv4.method manual \
                ipv4.addresses "${STATIC_IP}/${STATIC_PREFIX}" \
                ipv4.gateway "$STATIC_GATEWAY" \
                ipv4.dns "$STATIC_DNS" 2>&1 | tee -a "$LOG_FILE" || true
            sudo nmcli connection up "$wifi_conn_name" 2>&1 | tee -a "$LOG_FILE" || true
            ok "WiFi connection created with static IP"
        else
            # DHCP - use connection add + up so the password is passed as an
            # explicit property rather than a positional argument that nmcli
            # silently drops when the adapter isn't fully initialised.
            sudo nmcli connection add \
                type wifi con-name "$wifi_conn_name" \
                ifname wlan0 ssid "$WIFI_SSID" \
                wifi-sec.key-mgmt wpa-psk \
                wifi-sec.psk "$WIFI_PASSWORD" \
                ipv4.method auto 2>&1 | tee -a "$LOG_FILE" || true
            sudo nmcli connection up "$wifi_conn_name" 2>&1 | tee -a "$LOG_FILE" || true
            ok "WiFi connection created (DHCP)"
        fi
    fi

    # Wait for network connectivity (up to 60 seconds)
    info "Waiting for network connectivity..."
    net_ok=false
    for _i in $(seq 1 30); do
        if ping -c1 -W2 8.8.8.8 &>/dev/null; then
            net_ok=true
            break
        fi
        sleep 2
    done

    if [ "$net_ok" = true ]; then
        ok "Network connectivity confirmed"
    else
        warn "No connectivity after 60s - continuing anyway"
    fi
else
    info "No WIFI_SSID in provision.conf - assuming Ethernet"

    # Apply static IP to Ethernet if requested
    if [ -n "$STATIC_IP" ] && [ -n "$STATIC_GATEWAY" ]; then
        # Find the active Ethernet connection name
        eth_conn=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null \
            | grep "ethernet" | head -1 | cut -d: -f1)
        if [ -n "$eth_conn" ]; then
            apply_static_ip "$eth_conn"
            sudo nmcli connection up "$eth_conn" 2>/dev/null || true
        else
            warn "No active Ethernet connection found for static IP"
        fi
    fi

    # Verify connectivity
    if ping -c1 -W5 8.8.8.8 &>/dev/null; then
        ok "Network connectivity confirmed"
    else
        warn "No network connectivity detected - will retry operations anyway"
    fi
fi

# =====================================================================
# STEP 3: Install deploy key
# =====================================================================

log ""
log -e "${CYAN}[3/7] Installing fleet deploy key${NC}"

mkdir -p "${PI_HOME}/.ssh"
chmod 700 "${PI_HOME}/.ssh"

# Decode and install the private key
if echo "$DEPLOY_KEY_B64" | base64 -d > "$DEPLOY_KEY_FILE" 2>/dev/null; then
    chmod 600 "$DEPLOY_KEY_FILE"

    # Validate it looks like a real key
    if head -1 "$DEPLOY_KEY_FILE" | grep -q "BEGIN.*KEY"; then
        ok "Deploy key installed at ${DEPLOY_KEY_FILE}"
    else
        rm -f "$DEPLOY_KEY_FILE"
        abort "DEPLOY_KEY_B64 decoded but does not look like a valid SSH key."
    fi
else
    abort "Failed to base64-decode DEPLOY_KEY_B64. Check encoding."
fi

# Derive public key (used to verify the key is valid)
if ssh-keygen -y -f "$DEPLOY_KEY_FILE" > "${DEPLOY_KEY_FILE}.pub" 2>/dev/null; then
    ok "Public key derived"
else
    warn "Could not derive public key - git clone may still work"
fi

# Install admin SSH key for passwordless login
if [ -n "$ADMIN_SSH_KEY" ]; then
    touch "${PI_HOME}/.ssh/authorized_keys"
    chmod 600 "${PI_HOME}/.ssh/authorized_keys"
    if ! grep -qF "$ADMIN_SSH_KEY" "${PI_HOME}/.ssh/authorized_keys" 2>/dev/null; then
        echo "$ADMIN_SSH_KEY" >> "${PI_HOME}/.ssh/authorized_keys"
        ok "Admin SSH key added to authorized_keys"
    else
        ok "Admin SSH key already in authorized_keys"
    fi
fi

# Configure SSH to use this key for GitHub
if [ -f "$SSH_CONFIG" ] && grep -q "inventory_deploy" "$SSH_CONFIG" 2>/dev/null; then
    ok "SSH config already has deploy key entry"
else
    info "Configuring SSH for GitHub..."
    cat >> "$SSH_CONFIG" <<SSHCFG

Host github.com
    IdentityFile ${DEPLOY_KEY_FILE}
    IdentitiesOnly yes
SSHCFG
    chmod 600 "$SSH_CONFIG"
    ok "SSH config updated"
fi

# Add GitHub to known_hosts (avoid interactive prompt)
if ! grep -q "github.com" "${PI_HOME}/.ssh/known_hosts" 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com >> "${PI_HOME}/.ssh/known_hosts" 2>/dev/null
    ok "GitHub added to known_hosts"
fi

# Ensure git and ssh always use the deploy key regardless of which user
# the process runs as (sudo bash runs as root but key lives under PI_HOME)
export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY_FILE} -o UserKnownHostsFile=${PI_HOME}/.ssh/known_hosts -o IdentitiesOnly=yes"

fix_owner "${PI_HOME}/.ssh"

# =====================================================================
# STEP 4: Ensure git is available and clone the repo
# =====================================================================

log ""
log -e "${CYAN}[4/7] Repository setup${NC}"

if ! command -v git &>/dev/null; then
    info "Installing git..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq git >/dev/null 2>&1
    if command -v git &>/dev/null; then
        ok "git installed"
    else
        abort "git installation failed. Check network connectivity."
    fi
else
    ok "git available"
fi

# git 2.35.2+ refuses to operate on repos owned by a different user.
# Running as root on a PI_USER-owned repo triggers this on retry runs
# (fix_owner ran on the previous attempt and changed ownership to PI_USER).
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

if [ -d "${REPO_DIR}/.git" ]; then
    ok "Repo already cloned at ${REPO_DIR}"
    fix_owner "$REPO_DIR"
    cd "$REPO_DIR" || exit 1
    git pull --ff-only 2>&1 | tail -3 | tee -a "$LOG_FILE" || true
    cd "$PI_HOME" || exit 1
else
    info "Cloning repository..."
    # Verify SSH auth works before cloning
    if ssh -i "$DEPLOY_KEY_FILE" \
           -o "UserKnownHostsFile=${PI_HOME}/.ssh/known_hosts" \
           -o IdentitiesOnly=yes \
           -T git@github.com 2>&1 | grep -qi "successfully authenticated"; then
        ok "GitHub SSH authentication confirmed"
    else
        warn "GitHub SSH test did not confirm - attempting clone anyway"
    fi

    if git clone "$GITHUB_REPO" "$REPO_DIR" 2>&1 | tail -5 | tee -a "$LOG_FILE"; then
        ok "Repository cloned"
    else
        abort "Repository clone failed. Is the deploy key added to GitHub?"
    fi

    # Set up sparse checkout (client-only files)
    cd "$REPO_DIR" || exit 1
    git sparse-checkout init 2>/dev/null
    git sparse-checkout set --skip-checks client README.md .gitignore 2>/dev/null
    ok "Sparse checkout configured (client/, README.md, .gitignore)"
    cd "$PI_HOME" || exit 1
fi

fix_owner "$REPO_DIR"

# Validate the client directory exists
if [ ! -d "$CLIENT_DIR/scripts" ]; then
    abort "Client scripts directory not found at ${CLIENT_DIR}/scripts"
fi

# =====================================================================
# STEP 5: Run provision.sh (full provisioning)
# =====================================================================

log ""
log -e "${CYAN}[5/7] Running provisioner${NC}"
info "This may take several minutes on first run..."

PROVISION_SCRIPT="${CLIENT_DIR}/scripts/provision.sh"

if [ ! -f "$PROVISION_SCRIPT" ]; then
    abort "provision.sh not found at ${PROVISION_SCRIPT}"
fi

chmod +x "$PROVISION_SCRIPT"

# Run provision.sh directly (no pipe) so its stdout is never block-buffered.
# Piping through tee delays all output until the process exits, which pushes
# time-sensitive actions (test label print, buzzer) to the very end.
# provision.sh already writes its own ~/provision.log; append that afterward.
provision_exit=0
bash "$PROVISION_SCRIPT" || provision_exit=$?
cat "${PI_HOME}/provision.log" >> "$LOG_FILE" 2>/dev/null || true

if [ "$provision_exit" -ne 0 ]; then
    abort "provision.sh exited with code ${provision_exit}. Review ${PI_HOME}/provision.log for details."
fi

ok "Provisioning complete"
fix_owner "${PI_HOME}/.local" "${PI_HOME}/.cache" "${PI_HOME}/.cargo" "$REPO_DIR"

# =====================================================================
# STEP 6: Register with the server
# =====================================================================

log ""
log -e "${CYAN}[6/7] Registering with server${NC}"
info "Server: ${SERVER_URL}"

REGISTER_SCRIPT="${CLIENT_DIR}/scripts/register_client.sh"

if [ ! -f "$REGISTER_SCRIPT" ]; then
    abort "register_client.sh not found at ${REGISTER_SCRIPT}"
fi

chmod +x "$REGISTER_SCRIPT"

register_exit=0
bash "$REGISTER_SCRIPT" \
    --secret "$REGISTRATION_SECRET" \
    --server "$SERVER_URL" \
    --env-file "${CLIENT_DIR}/.env" \
    --service "inventory-client" \
    2>&1 | tee -a "$LOG_FILE" || register_exit=$?

if [ "$register_exit" -ne 0 ]; then
    abort "register_client.sh exited with code ${register_exit}. Registration will retry on next boot."
fi

ok "Registration complete"
fix_owner "${CLIENT_DIR}/.env" "${PI_HOME}/.ssh"

# =====================================================================
# STEP 7: Clean up - zero secrets, remove flag, disable service
# =====================================================================

log ""
log -e "${CYAN}[7/7] Cleanup${NC}"

# Zero sensitive fields in provision.conf (leave SERVER_URL as a record)
info "Zeroing sensitive fields in provision.conf..."
sudo sed -i 's/^REGISTRATION_SECRET=.*/REGISTRATION_SECRET=/' "$PROVISION_CONF"
sudo sed -i 's/^DEPLOY_KEY_B64=.*/DEPLOY_KEY_B64=/' "$PROVISION_CONF"
sudo sed -i 's/^WIFI_PASSWORD=.*/WIFI_PASSWORD=/' "$PROVISION_CONF"
sudo sed -i 's/^STATIC_DNS=.*/STATIC_DNS=/' "$PROVISION_CONF"
ok "Sensitive fields zeroed in provision.conf"

# Remove the first-boot flag file
sudo rm -f "$FLAG_FILE"
ok "Flag file removed: ${FLAG_FILE}"

# Disable and remove the setup service (its job is done).
# Do NOT call systemctl daemon-reload here: this script runs as the service's
# own ExecStart process, so daemon-reload while still running causes systemd
# to mark the unit failed mid-execution. systemd's normal boot-time reload on
# the next boot will see the file is gone and stop tracking the unit cleanly.
info "Removing inventory-setup service..."
sudo systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
ok "inventory-setup.service removed"

# =====================================================================
# DONE
# =====================================================================

log ""
log -e "${GREEN}==================================================${NC}"
log -e "${GREEN}  First-boot setup complete${NC}"
log -e "${GREEN}==================================================${NC}"
log ""
log -e "${GRAY}The Pi is now registered and pending admin approval.${NC}"
log -e "${GRAY}Accept the station in the server admin UI, then the${NC}"
log -e "${GRAY}VPN tunnel will activate and scanning can begin.${NC}"
log ""
log -e "${GRAY}On all future boots, inventory-provision.service${NC}"
log -e "${GRAY}will maintain the configuration automatically.${NC}"
log ""
log -e "${GRAY}Log: ${LOG_FILE}${NC}"

exit 0
