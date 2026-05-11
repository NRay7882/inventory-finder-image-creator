#!/usr/bin/env bash
# setup.sh - Prerequisites check and setup for provision-image.sh
#
# Run once on macOS or Linux before using provision-image.sh for the first time.
#
# Checks and optionally installs:
#   - Raspberry Pi Imager (required for full mode)
#   - xz-utils (fallback for .xz images without rpi-imager)
#   - Python 3 (required for firstrun.sh generation in full mode)
#
# Also checks:
#   - Fleet deploy private key (~/.ssh/inventory_deploy)
#   - Admin SSH public key (~/.ssh/id_ed25519.pub)
#
# Usage: ./setup.sh

set -euo pipefail

RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

step() { printf "  ${CYAN}-> %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}OK %s${NC}\n" "$*"; }
warn() { printf "  ${YELLOW}** %s${NC}\n" "$*"; }

OS_TYPE="$(uname -s)"
ALL_OK=true

printf '\n'
printf "${CYAN}================================================${NC}\n"
printf "${CYAN}  Inventory Pi - Setup Check${NC}\n"
printf "${CYAN}================================================${NC}\n"
printf '\n'

# ── Raspberry Pi Imager ───────────────────────────────────────────────────────

step "Checking for Raspberry Pi Imager..."

find_rpi_imager() {
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        for p in \
            "/Applications/Imager.app/Contents/MacOS/rpi-imager" \
            "/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"; do
            [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
        done
    else
        for p in "/usr/bin/rpi-imager" "/usr/local/bin/rpi-imager"; do
            [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
        done
    fi
    command -v rpi-imager 2>/dev/null || return 1
}

imager=$(find_rpi_imager 2>/dev/null || true)
if [[ -n "$imager" ]]; then
    ok "Raspberry Pi Imager found: $imager"
else
    warn "Raspberry Pi Imager not found."
    ALL_OK=false

    if [[ "$OS_TYPE" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            printf "  Install via Homebrew? [y/N] "
            read -r answer </dev/tty
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                step "Running: brew install --cask raspberry-pi-imager"
                brew install --cask raspberry-pi-imager
                imager=$(find_rpi_imager 2>/dev/null || true)
                if [[ -n "$imager" ]]; then
                    ok "Raspberry Pi Imager installed: $imager"
                    ALL_OK=true
                else
                    warn "Install finished but rpi-imager not found at expected path."
                fi
            else
                printf "  ${GRAY}Install manually from: https://www.raspberrypi.com/software/${NC}\n"
            fi
        else
            warn "Homebrew not available."
            printf "  ${GRAY}Install Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${NC}\n"
            printf "  ${GRAY}Then run: brew install --cask raspberry-pi-imager${NC}\n"
            printf "  ${GRAY}Or install manually from: https://www.raspberrypi.com/software/${NC}\n"
        fi
    else
        if command -v apt-get &>/dev/null; then
            printf "  Install via apt? [y/N] "
            read -r answer </dev/tty
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                step "Running: sudo apt-get install rpi-imager"
                sudo apt-get update -qq
                sudo apt-get install -y rpi-imager
                imager=$(find_rpi_imager 2>/dev/null || true)
                if [[ -n "$imager" ]]; then
                    ok "Raspberry Pi Imager installed."
                    ALL_OK=true
                else
                    warn "apt install succeeded but rpi-imager not found on PATH."
                fi
            else
                printf "  ${GRAY}Run manually: sudo apt-get install rpi-imager${NC}\n"
                printf "  ${GRAY}Or install from: https://www.raspberrypi.com/software/${NC}\n"
            fi
        else
            printf "  ${GRAY}Install manually from: https://www.raspberrypi.com/software/${NC}\n"
        fi
    fi
fi

# ── xz ───────────────────────────────────────────────────────────────────────

printf '\n'
step "Checking for xz (fallback for .xz images without rpi-imager)..."

if command -v xzcat &>/dev/null || command -v xz &>/dev/null; then
    ok "xz available"
else
    warn "xz not found - only needed when using the dd fallback with .xz images"
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        printf "  ${GRAY}Install with: brew install xz${NC}\n"
    elif command -v apt-get &>/dev/null; then
        printf "  ${GRAY}Install with: sudo apt-get install xz-utils${NC}\n"
    fi
fi

# ── Python 3 ─────────────────────────────────────────────────────────────────

printf '\n'
step "Checking for Python 3 (required for firstrun.sh generation in full mode)..."

if command -v python3 &>/dev/null; then
    py_ver=$(python3 --version 2>&1)
    ok "Python 3 available: $py_ver"
else
    warn "python3 not found"
    ALL_OK=false
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        printf "  ${GRAY}Install with: brew install python3${NC}\n"
    elif command -v apt-get &>/dev/null; then
        printf "  ${GRAY}Install with: sudo apt-get install python3${NC}\n"
    fi
fi

# ── Deploy key ────────────────────────────────────────────────────────────────

printf '\n'
step "Checking for fleet deploy key..."

deploy_key="$HOME/.ssh/inventory_deploy"
if [[ -f "$deploy_key" ]]; then
    if head -c 40 "$deploy_key" | grep -q "BEGIN.*KEY"; then
        ok "Deploy key found: $deploy_key"
    else
        warn "File found but does not look like an SSH private key: $deploy_key"
        ALL_OK=false
    fi
else
    warn "Deploy key not found at $deploy_key"
    printf "  ${GRAY}Place the fleet deploy private key at $deploy_key${NC}\n"
    printf "  ${GRAY}or pass --deploy-key PATH when running provision-image.sh${NC}\n"
    ALL_OK=false
fi

# ── Admin SSH public key ──────────────────────────────────────────────────────

printf '\n'
step "Checking for admin SSH public key (optional)..."

admin_key="$HOME/.ssh/id_ed25519.pub"
if [[ -f "$admin_key" ]]; then
    if head -1 "$admin_key" | grep -q "^ssh-"; then
        ok "Admin SSH public key found: $admin_key"
    else
        warn "File found but does not look like an SSH public key: $admin_key"
    fi
else
    warn "Admin SSH public key not found at $admin_key (optional)"
    printf "  ${GRAY}Pass --admin-ssh-key PATH to provision-image.sh, or --admin-ssh-key '' to skip${NC}\n"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n'
if $ALL_OK; then
    printf "${GREEN}================================================${NC}\n"
    printf "${GREEN}  Ready. Run ./provision-image.sh to prepare an SD card.${NC}\n"
    printf "${GREEN}================================================${NC}\n"
else
    printf "${YELLOW}================================================${NC}\n"
    printf "${YELLOW}  Some prerequisites are missing. See warnings above.${NC}\n"
    printf "${GRAY}  provision-image.sh will prompt for anything not found automatically.${NC}\n"
    printf "${YELLOW}================================================${NC}\n"
fi
printf '\n'
