#!/usr/bin/env bash
# provision-image.sh - Raspberry Pi SD card preparation for Mac/Linux
#
# Two modes:
#
#   Full mode (--image-path provided):
#     1. Flashes the OS image via rpi-imager CLI or dd.
#     2. Writes firstrun.sh (hostname, user, SSH, WiFi, locale).
#     3. Writes provision.conf (deploy key, registration secret, etc.).
#
#   Provision-only mode (--image-path omitted):
#     Writes provision.conf to an already-mounted boot partition.
#
# Secrets are prompted securely unless supplied as arguments.
# REGISTRATION_SECRET is read from server/.env automatically when present.
#
# Usage: ./provision-image.sh [--image-path PATH] [options]
#        ./provision-image.sh --help

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

step() { printf "  ${CYAN}-> %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}OK %s${NC}\n" "$*"; }
warn() { printf "  ${YELLOW}** %s${NC}\n" "$*"; }
fail() { printf "  ${RED}XX %s${NC}\n" "$*" >&2; exit 1; }

read_secure() {
    local prompt="$1" val
    printf '%s: ' "$prompt" >/dev/tty
    read -rs val </dev/tty
    printf '\n' >/dev/tty
    printf '%s' "$val"
}

prompt_line() {
    local prompt="$1" default="${2:-}" val
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi
    read -r val </dev/tty
    printf '%s' "${val:-$default}"
}

# ── Defaults ──────────────────────────────────────────────────────────────────

IMAGE_PATH=""
DISK_DEVICE=""
BOOT_MOUNT=""

PI_HOSTNAME="rpi5-inventory"
PI_USERNAME="rpi5"
USER_PASSWORD=""
TIMEZONE="America/New_York"
KEYBOARD_LAYOUT="us"

WIFI_SSID=""
WIFI_PASSWORD=""
WIFI_COUNTRY="US"
WIFI_SECURITY="wpa2"
WIFI_HIDDEN="false"

LOCALE="en_US.UTF-8"

SERVER_URL=""
REGISTRATION_SECRET=""
DEPLOY_KEY_PATH="$HOME/.ssh/inventory_deploy"
ADMIN_SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"

STATIC_IP=""
STATIC_GATEWAY=""
STATIC_PREFIX="24"
STATIC_DNS="8.8.8.8,1.1.1.1"

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./provision-image.sh [options]

  --image-path PATH          .img or .img.xz file (triggers full mode)
  --disk DEVICE              SD card device (e.g. /dev/disk4 or /dev/sdb)
  --boot-mount PATH          Boot partition mount (e.g. /Volumes/bootfs)

  --hostname NAME            Pi hostname (default: rpi5-inventory)
  --username NAME            Pi OS user to create (default: rpi5)
  --timezone TZ              Timezone (default: America/New_York)
  --keyboard LAYOUT          Keyboard layout (default: us)
  --locale LOCALE            System locale (default: en_US.UTF-8)

  --wifi-ssid SSID           WiFi SSID (omit for Ethernet-only)
  --wifi-password PASS       WiFi password (prompted if SSID is set)
  --wifi-country CODE        WiFi country code (default: US)
  --wifi-security TYPE       wpa2 (default) or open
  --wifi-hidden              Network has a hidden SSID

  --server-url URL           Server URL (e.g. http://192.168.2.100:8000)
  --registration-secret S    Registration secret from server .env
  --deploy-key PATH          Fleet deploy private key (default: ~/.ssh/inventory_deploy)
  --admin-ssh-key PATH       Admin SSH public key (default: ~/.ssh/id_ed25519.pub)
                             Pass "" to skip

  --static-ip IP             Static IP (omit for DHCP)
  --static-gateway GW        Default gateway
  --static-prefix N          Network prefix length (default: 24)
  --static-dns DNS           DNS servers (default: 8.8.8.8,1.1.1.1)

  --help                     Show this help

Examples:
  Full mode (flash + configure):
    ./provision-image.sh --image-path ~/Downloads/raspios-trixie-arm64-lite.img.xz

  Provision-only (already flashed card):
    ./provision-image.sh
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-path)          IMAGE_PATH="$2";           shift 2 ;;
        --disk)                DISK_DEVICE="$2";          shift 2 ;;
        --boot-mount)          BOOT_MOUNT="$2";           shift 2 ;;
        --hostname)            PI_HOSTNAME="$2";          shift 2 ;;
        --username)            PI_USERNAME="$2";          shift 2 ;;
        --timezone)            TIMEZONE="$2";             shift 2 ;;
        --keyboard)            KEYBOARD_LAYOUT="$2";      shift 2 ;;
        --locale)              LOCALE="$2";               shift 2 ;;
        --wifi-ssid)           WIFI_SSID="$2";            shift 2 ;;
        --wifi-password)       WIFI_PASSWORD="$2";        shift 2 ;;
        --wifi-country)        WIFI_COUNTRY="$2";         shift 2 ;;
        --wifi-security)       WIFI_SECURITY="$2";        shift 2 ;;
        --wifi-hidden)         WIFI_HIDDEN="true";        shift   ;;
        --server-url)          SERVER_URL="$2";           shift 2 ;;
        --registration-secret) REGISTRATION_SECRET="$2"; shift 2 ;;
        --deploy-key)          DEPLOY_KEY_PATH="$2";      shift 2 ;;
        --admin-ssh-key)       ADMIN_SSH_KEY_PATH="$2";   shift 2 ;;
        --static-ip)           STATIC_IP="$2";            shift 2 ;;
        --static-gateway)      STATIC_GATEWAY="$2";       shift 2 ;;
        --static-prefix)       STATIC_PREFIX="$2";        shift 2 ;;
        --static-dns)          STATIC_DNS="$2";           shift 2 ;;
        --help|-h)             usage ;;
        *) fail "Unknown option: $1. Run with --help for usage." ;;
    esac
done

OS_TYPE="$(uname -s)"  # Darwin or Linux
FULL_MODE=false
[[ -n "$IMAGE_PATH" ]] && FULL_MODE=true
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Header ────────────────────────────────────────────────────────────────────

printf '\n'
printf "${CYAN}================================================${NC}\n"
printf "${CYAN}  Inventory Pi - Image Preparation${NC}\n"
printf "${CYAN}================================================${NC}\n"
if $FULL_MODE; then
    printf "${GRAY}  Mode: Flash + Customise + Provision${NC}\n"
else
    printf "${GRAY}  Mode: Provision only${NC}\n"
fi
printf '\n'

# ── Disk helpers ──────────────────────────────────────────────────────────────

find_rpi_imager() {
    local candidate
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        for candidate in \
            "/Applications/Imager.app/Contents/MacOS/rpi-imager" \
            "/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"; do
            [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
        done
    else
        for candidate in "/usr/bin/rpi-imager" "/usr/local/bin/rpi-imager"; do
            [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
        done
    fi
    command -v rpi-imager 2>/dev/null || return 1
}

find_boot_mount() {
    local mp
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        for mp in /Volumes/bootfs /Volumes/*/; do
            mp="${mp%/}"
            [[ -f "$mp/cmdline.txt" ]] && { printf '%s' "$mp"; return 0; }
        done
    else
        for mp in \
            "/media/$USER/bootfs" \
            "/media/bootfs" \
            "/run/media/$USER/bootfs" \
            "/mnt/bootfs"; do
            [[ -f "$mp/cmdline.txt" ]] && { printf '%s' "$mp"; return 0; }
        done
        if command -v findmnt &>/dev/null; then
            while IFS= read -r mp; do
                [[ -f "$mp/cmdline.txt" ]] && { printf '%s' "$mp"; return 0; }
            done < <(findmnt -n -l -o TARGET 2>/dev/null)
        fi
    fi
    return 1
}

# ── Step 1: Flash image (full mode only) ──────────────────────────────────────

if $FULL_MODE; then
    [[ -f "$IMAGE_PATH" ]] || fail "Image file not found: $IMAGE_PATH"

    if [[ -z "$DISK_DEVICE" ]]; then
        step "Searching for removable disks..."
        printf '\n'

        removable=()
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            printf '  External disks:\n'
            while IFS= read -r line; do
                dev=$(printf '%s' "$line" | awk '{print $1}')
                [[ "$dev" == /dev/disk* ]] || continue
                removable+=("$dev")
                size=$(diskutil info "$dev" 2>/dev/null | awk -F'[()]' '/Disk Size/{print $2; exit}')
                printf '    %s  (%s)\n' "$dev" "$size"
            done < <(diskutil list external physical 2>/dev/null)
        else
            printf '  Removable block devices:\n'
            while IFS= read -r line; do
                name=$(printf '%s' "$line" | awk '{print $1}')
                size=$(printf '%s' "$line" | awk '{print $2}')
                tran=$(printf '%s' "$line" | awk '{print $3}')
                hot=$(printf '%s' "$line" | awk '{print $4}')
                if [[ "$hot" == "1" || "$tran" == "usb" ]]; then
                    removable+=("/dev/$name")
                    printf '    /dev/%s  (%s)\n' "$name" "$size"
                fi
            done < <(lsblk -d -n -o NAME,SIZE,TRAN,HOTPLUG 2>/dev/null)
        fi

        printf '\n'
        if [[ ${#removable[@]} -eq 0 ]]; then
            fail "No removable disk found. Insert the SD card and try again."
        elif [[ ${#removable[@]} -eq 1 ]]; then
            DISK_DEVICE="${removable[0]}"
            ok "SD card: $DISK_DEVICE"
        else
            warn "Multiple removable disks found."
            DISK_DEVICE=$(prompt_line "Enter device path (e.g. /dev/disk4 or /dev/sdb)")
        fi
    fi

    printf '\n'
    printf "  ${YELLOW}About to flash:${NC}\n"
    printf "  ${YELLOW}  Source: %s${NC}\n" "$(basename "$IMAGE_PATH")"
    printf "  ${YELLOW}  Target: %s${NC}\n" "$DISK_DEVICE"
    printf "  ${RED}  WARNING: ALL DATA ON THE DISK WILL BE ERASED${NC}\n"
    printf '\n'
    confirm=$(prompt_line "Type YES to continue")
    [[ "$confirm" == "YES" ]] || { printf 'Aborted.\n'; exit 0; }

    step "Unmounting $DISK_DEVICE..."
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        diskutil unmountDisk "$DISK_DEVICE" 2>/dev/null || warn "Could not unmount - proceeding"
    else
        while IFS= read -r mp; do
            [[ -n "$mp" ]] && sudo umount "$mp" 2>/dev/null || true
        done < <(lsblk -n -o MOUNTPOINT "$DISK_DEVICE" 2>/dev/null)
        for part in "${DISK_DEVICE}"*[0-9]; do
            [[ -b "$part" ]] && sudo umount "$part" 2>/dev/null || true
        done
    fi

    imager=$(find_rpi_imager 2>/dev/null || true)
    if [[ -n "$imager" ]]; then
        ok "Raspberry Pi Imager: $imager"
        step "Flashing image (this takes several minutes)..."
        printf '\n'
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            "$imager" --cli "$IMAGE_PATH" "$DISK_DEVICE" || fail "rpi-imager failed."
        else
            sudo "$imager" --cli "$IMAGE_PATH" "$DISK_DEVICE" || fail "rpi-imager failed."
        fi
    else
        warn "rpi-imager not found - falling back to dd."
        if [[ "$IMAGE_PATH" == *.xz ]]; then
            command -v xzcat &>/dev/null || \
                fail "xzcat required for .xz images. Install: 'brew install xz' or 'apt install xz-utils'."
        fi
        step "Flashing via dd (this takes several minutes)..."
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            raw_dev="${DISK_DEVICE/\/dev\/disk//dev/rdisk}"
            printf '  No progress indicator on macOS; SD card LED activity shows writing.\n'
            if [[ "$IMAGE_PATH" == *.xz ]]; then
                xzcat "$IMAGE_PATH" | sudo dd of="$raw_dev" bs=4m
            else
                sudo dd if="$IMAGE_PATH" of="$raw_dev" bs=4m
            fi
        else
            if [[ "$IMAGE_PATH" == *.xz ]]; then
                xzcat "$IMAGE_PATH" | sudo dd of="$DISK_DEVICE" bs=4M status=progress conv=fsync
            else
                sudo dd if="$IMAGE_PATH" of="$DISK_DEVICE" bs=4M status=progress conv=fsync
            fi
        fi
        sudo sync
    fi
    ok "Image written"

    if [[ "$OS_TYPE" == "Darwin" ]]; then
        diskutil eject "$DISK_DEVICE" 2>/dev/null || true
    fi

    printf '\n'
    printf '  Remove and re-insert the SD card, then press Enter...\n'
    read -r </dev/tty

    step "Waiting for boot partition to mount (up to 60 s)..."
    BOOT_MOUNT=""
    elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        BOOT_MOUNT=$(find_boot_mount 2>/dev/null || true)
        [[ -n "$BOOT_MOUNT" ]] && break
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ -z "$BOOT_MOUNT" ]]; then
        warn "Boot partition not detected automatically."
        BOOT_MOUNT=$(prompt_line "Enter boot partition mount path (e.g. /Volumes/bootfs)")
    fi
    ok "Boot partition: $BOOT_MOUNT"
fi

# ── Step 2: Find boot partition (provision-only mode) ─────────────────────────

if [[ -z "$BOOT_MOUNT" ]]; then
    step "Looking for boot partition (label 'bootfs')..."
    BOOT_MOUNT=$(find_boot_mount 2>/dev/null || true)

    if [[ -n "$BOOT_MOUNT" ]]; then
        ok "Boot partition: $BOOT_MOUNT"
    else
        warn "No boot partition found automatically."
        BOOT_MOUNT=$(prompt_line "Enter boot partition mount path (e.g. /Volumes/bootfs or /media/user/bootfs)")
    fi
fi

[[ -d "$BOOT_MOUNT" ]] || fail "Boot mount path not found: $BOOT_MOUNT"

# ── Step 3: Credentials and firstrun.sh (full mode only) ─────────────────────

if $FULL_MODE; then
    printf '\n'
    printf "${CYAN}================================================${NC}\n"
    printf "${CYAN}  Step 3: Enter credentials for the Pi image${NC}\n"
    printf "${CYAN}================================================${NC}\n"
    printf '\n'

    if [[ -z "$USER_PASSWORD" ]]; then
        USER_PASSWORD=$(read_secure "Password for Pi user '$PI_USERNAME'")
        pw_confirm=$(read_secure "Confirm password for '$PI_USERNAME'")
        [[ "$USER_PASSWORD" == "$pw_confirm" ]] || fail "Passwords do not match."
    fi
    [[ -n "$USER_PASSWORD" ]] || fail "User password is required in full mode."

    if [[ -n "$WIFI_SSID" && "$WIFI_SECURITY" != "open" && -z "$WIFI_PASSWORD" ]]; then
        WIFI_PASSWORD=$(read_secure "WiFi password for '$WIFI_SSID'")
        wifi_pw_confirm=$(read_secure "Confirm WiFi password for '$WIFI_SSID'")
        [[ "$WIFI_PASSWORD" == "$wifi_pw_confirm" ]] || fail "WiFi passwords do not match."
    fi

    # Write plain-text password for chpasswd - no shell escaping, hashed on the Pi
    printf '%s:%s\n' "$PI_USERNAME" "$USER_PASSWORD" > "$BOOT_MOUNT/userpassword.txt"
    ok "Credentials staged (deleted on first boot)"

    wifi_hidden_int=0
    [[ "$WIFI_HIDDEN" == "true" ]] && wifi_hidden_int=1

    if [[ -n "$WIFI_SSID" ]]; then
        if [[ "$WIFI_SECURITY" == "open" ]]; then
            WIFI_BLOCK='if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wpa '"'"'__SSID__'"'"' '"'"''"'"' '"'"'__COUNTRY__'"'"'
else
   cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'"'"'WPAEOF'"'"'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=__COUNTRY__

network={
    ssid="__SSID__"
    key_mgmt=NONE
    scan_ssid=__WIFI_HIDDEN_INT__
}
WPAEOF
   chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
fi'
        else
            WIFI_BLOCK='if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wpa '"'"'__SSID__'"'"' '"'"'__WIFIPW__'"'"' '"'"'__COUNTRY__'"'"'
else
   cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'"'"'WPAEOF'"'"'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=__COUNTRY__

network={
    ssid="__SSID__"
    psk="__WIFIPW__"
    scan_ssid=__WIFI_HIDDEN_INT__
}
WPAEOF
   chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
fi'
        fi
    else
        WIFI_BLOCK='# No WiFi configured - Ethernet-only deployment'
    fi

    # Write all substitution values to temp files so Python can read them
    # safely without any shell escaping concerns.
    tmpdir=$(mktemp -d)
    printf '%s' "$PI_HOSTNAME"       > "$tmpdir/hostname"
    printf '%s' "$PI_USERNAME"       > "$tmpdir/username"
    printf '%s' "$WIFI_SSID"         > "$tmpdir/ssid"
    printf '%s' "$WIFI_PASSWORD"     > "$tmpdir/wifipw"
    printf '%s' "$WIFI_COUNTRY"      > "$tmpdir/country"
    printf '%s' "$KEYBOARD_LAYOUT"   > "$tmpdir/keyboard"
    printf '%s' "$TIMEZONE"          > "$tmpdir/timezone"
    printf '%s' "$LOCALE"            > "$tmpdir/locale"
    printf '%s' "$wifi_hidden_int"   > "$tmpdir/wifi_hidden_int"
    printf '%s' "$WIFI_BLOCK"        > "$tmpdir/wifi_block"

    python3 - "$tmpdir" "$BOOT_MOUNT/firstrun.sh" <<'PYEOF'
import sys

tmpdir = sys.argv[1]
dest   = sys.argv[2]

def rd(name):
    with open(f'{tmpdir}/{name}') as f:
        return f.read()

hostname    = rd('hostname')
username    = rd('username')
ssid        = rd('ssid')
wifipw      = rd('wifipw')
country     = rd('country')
keyboard    = rd('keyboard')
timezone    = rd('timezone')
locale      = rd('locale')
wifi_hidden = rd('wifi_hidden_int')
wifi_block  = rd('wifi_block')

# r-string so backslashes are literal - matches firstrun.sh bash syntax exactly
template = r"""#!/bin/bash
# firstrun.sh - generated by provision-image.sh
set +e

CURRENT_HOSTNAME=`cat /etc/hostname | tr -d " \t\n\r"`
FIRSTUSER=`getent passwd 1000 | cut -d: -f1`
FIRSTUSERHOME=`getent passwd 1000 | cut -d: -f6`

# Hostname
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_hostname __HOSTNAME__
else
   echo __HOSTNAME__ >/etc/hostname
   sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t__HOSTNAME__/g" /etc/hosts
fi

# User account - rename the default UID-1000 user if needed, or create if absent
if [ -n "$FIRSTUSER" ] && [ "$FIRSTUSER" != "__USERNAME__" ]; then
   usermod -l "__USERNAME__" "$FIRSTUSER"
   usermod -m -d /home/__USERNAME__ "__USERNAME__"
   groupmod -n "__USERNAME__" "$FIRSTUSER"
elif [ -z "$FIRSTUSER" ]; then
   useradd -m -s /bin/bash "__USERNAME__"
   usermod -aG sudo,adm,dialout,cdrom,audio,video,plugdev,input,netdev,gpio,i2c,spi "__USERNAME__" 2>/dev/null || true
fi
# Pi OS Trixie sets the default UID-1000 user shell to /usr/sbin/nologin to
# force the setup wizard. Explicitly set bash so SSH sessions are not rejected.
usermod -s /bin/bash "__USERNAME__"
# Set password from file - chpasswd reads user:plaintext directly with no
# shell escaping, then hashes it itself. File is deleted immediately after.
chpasswd < /boot/firmware/userpassword.txt
rm -f /boot/firmware/userpassword.txt

# SSH
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom enable_ssh
else
   systemctl enable ssh
fi

# Allow password authentication over SSH (provision.sh can tighten this later)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true

# WiFi
__WIFI_BLOCK__

# Keyboard and timezone
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_keymap '__KEYBOARD__'
   /usr/lib/raspberrypi-sys-mods/imager_custom set_timezone '__TIMEZONE__'
else
   rm -f /etc/localtime
   echo "__TIMEZONE__" >/etc/timezone
   dpkg-reconfigure -f noninteractive tzdata
   cat >/etc/default/keyboard <<'KBEOF'
XKBMODEL="pc105"
XKBLAYOUT="__KEYBOARD__"
XKBVARIANT=""
XKBOPTIONS=""
KBEOF
   dpkg-reconfigure -f noninteractive keyboard-configuration
fi

# Locale
sed -i 's/^# *\(__LOCALE__\)/\1/' /etc/locale.gen 2>/dev/null || true
locale-gen 2>/dev/null || true
update-locale LANG=__LOCALE__ 2>/dev/null || true

# Headless server target - graphical.target is for desktop environments.
# multi-user.target is the correct default for a server/headless Pi.
systemctl set-default multi-user.target 2>/dev/null || true

# Prevent NetworkManager from blocking boot when the network is not immediately
# available. Without this, the boot hangs at graphical.target waiting for a
# fully established connection before releasing to the login prompt.
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true

# Disable cloud-init - it looks for a cloud metadata server that does not exist
# on a local network and will hang Boot 2 indefinitely waiting for a response.
touch /etc/cloud/cloud-init.disabled
for svc in cloud-init cloud-init-local cloud-config cloud-final; do
   systemctl disable "$svc" 2>/dev/null || true
   systemctl mask "$svc" 2>/dev/null || true
done

# Disable Pi OS first-boot wizard and Raspberry Pi Connect (rpi-connect).
# userconfig.service owns tty1 on first boot - masking it removes the tty1
# handler entirely. Disable only so it exits cleanly when the user is already
# configured, then explicitly enable the standard getty to take over tty1.
rm -f /etc/xdg/autostart/piwiz.desktop 2>/dev/null || true
for svc in raspi-config userconfig; do
   systemctl disable "$svc" 2>/dev/null || true
done
for svc in rpi-connect rpi-connect-wayland-proxy; do
   systemctl disable "$svc" 2>/dev/null || true
   systemctl mask "$svc" 2>/dev/null || true
done
systemctl enable getty@tty1.service 2>/dev/null || true

# Install first_boot.sh and the inventory-setup service.
# first_boot.sh (copied from the boot partition) handles: WiFi via NetworkManager,
# deploy key installation, repo clone, full provisioning, and server registration.
# The flag file prevents re-runs; first_boot.sh removes it on success.
mkdir -p /opt/inventory /etc/inventory
cp /boot/firmware/first_boot.sh /opt/inventory/first_boot.sh
chmod +x /opt/inventory/first_boot.sh
rm -f /boot/firmware/first_boot.sh
touch /etc/inventory/first-boot-pending

cat >/etc/systemd/system/inventory-setup.service <<'SVCEOF'
[Unit]
Description=Inventory Client - First Boot Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/inventory/first-boot-pending

[Service]
Type=oneshot
User=root
Environment="PI_USER=__USERNAME__"
ExecStart=/bin/bash /opt/inventory/first_boot.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable inventory-setup.service 2>/dev/null || true

# Clean up - remove this script and the kernel cmdline trigger
rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/firmware/cmdline.txt
exit 0
"""

content = template.lstrip('\n')

# Substitute wifi-specific tokens within the block first - these tokens only
# appear inside wifi_block, not in the main template, so they must be resolved
# before the block is inserted.
wifi_block = wifi_block.replace('__SSID__',            ssid)
wifi_block = wifi_block.replace('__WIFIPW__',          wifipw)
wifi_block = wifi_block.replace('__COUNTRY__',         country)
wifi_block = wifi_block.replace('__WIFI_HIDDEN_INT__', wifi_hidden)

content = content.replace('__WIFI_BLOCK__',      wifi_block)
content = content.replace('__HOSTNAME__',        hostname)
content = content.replace('__USERNAME__',        username)
content = content.replace('__KEYBOARD__',        keyboard)
content = content.replace('__TIMEZONE__',        timezone)
content = content.replace('__LOCALE__',          locale)

with open(dest, 'w', newline='\n') as f:
    f.write(content)
PYEOF
    rm -rf "$tmpdir"
    ok "firstrun.sh written: $BOOT_MOUNT/firstrun.sh"

    first_boot_src="$SCRIPT_DIR/first_boot.sh"
    [[ -f "$first_boot_src" ]] || fail "first_boot.sh not found at $first_boot_src"
    tr -d '\r' < "$first_boot_src" > "$BOOT_MOUNT/first_boot.sh"
    ok "first_boot.sh written to boot partition"

    cmdline_path="$BOOT_MOUNT/cmdline.txt"
    if [[ -f "$cmdline_path" ]]; then
        cmdline=$(tr -d '\r\n' < "$cmdline_path")
        if [[ "$cmdline" != *"systemd.run="* ]]; then
            trigger=" systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.run_failure_action=reboot"
            printf '%s\n' "${cmdline}${trigger}" > "$cmdline_path"
            ok "cmdline.txt updated to trigger firstrun.sh on boot"
        else
            ok "cmdline.txt already has systemd.run entry"
        fi
    else
        warn "cmdline.txt not found - firstrun.sh will not run automatically"
    fi
fi

# ── Step 4: provision.conf ────────────────────────────────────────────────────

if [[ -z "$SERVER_URL" ]]; then
    default_url=""
    server_env="$SCRIPT_DIR/../../server/.env"
    if [[ -f "$server_env" ]]; then
        url_line=$(grep "^SERVER_URL=" "$server_env" 2>/dev/null | head -1 || true)
        [[ -n "$url_line" ]] && default_url="${url_line#SERVER_URL=}"
    fi
    if [[ -z "$default_url" ]]; then
        if [[ "$OS_TYPE" == "Darwin" ]]; then
            local_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
        else
            local_ip=$(ip route get 1 2>/dev/null | awk '/src/{print $7; exit}' || \
                       hostname -I 2>/dev/null | awk '{print $1}' || true)
        fi
        [[ -n "${local_ip:-}" ]] && default_url="http://${local_ip}:8000"
    fi
    SERVER_URL=$(prompt_line "Server URL" "$default_url")
fi
[[ -n "$SERVER_URL" ]] || fail "SERVER_URL is required."
ok "Server URL: $SERVER_URL"

if [[ -z "$REGISTRATION_SECRET" ]]; then
    server_env="$SCRIPT_DIR/../../server/.env"
    if [[ -f "$server_env" ]]; then
        sec_line=$(grep "^REGISTRATION_SECRET=" "$server_env" 2>/dev/null | head -1 || true)
        if [[ -n "$sec_line" ]]; then
            REGISTRATION_SECRET="${sec_line#REGISTRATION_SECRET=}"
            ok "Registration secret: read from server/.env"
        fi
    fi
fi
if [[ -z "$REGISTRATION_SECRET" ]]; then
    REGISTRATION_SECRET=$(read_secure "Registration secret (REGISTRATION_SECRET from server .env)")
fi
[[ -n "$REGISTRATION_SECRET" ]] || fail "REGISTRATION_SECRET is required."

if [[ ! -f "$DEPLOY_KEY_PATH" ]]; then
    DEPLOY_KEY_PATH=$(prompt_line "Path to fleet deploy private key")
fi
[[ -f "$DEPLOY_KEY_PATH" ]] || fail "Deploy key not found: $DEPLOY_KEY_PATH"
key_header=$(head -c 40 "$DEPLOY_KEY_PATH")
[[ "$key_header" == *"BEGIN"*"KEY"* ]] || fail "Not an SSH private key: $DEPLOY_KEY_PATH"

if [[ "$OS_TYPE" == "Darwin" ]]; then
    DEPLOY_KEY_B64=$(base64 -i "$DEPLOY_KEY_PATH")
else
    DEPLOY_KEY_B64=$(base64 -w 0 "$DEPLOY_KEY_PATH")
fi
ok "Deploy key: $DEPLOY_KEY_PATH"

ADMIN_SSH_KEY=""
if [[ -n "$ADMIN_SSH_KEY_PATH" && -f "$ADMIN_SSH_KEY_PATH" ]]; then
    key_content=$(cat "$ADMIN_SSH_KEY_PATH")
    if [[ "$key_content" == ssh-* ]]; then
        ADMIN_SSH_KEY="$key_content"
        ok "Admin SSH key: $ADMIN_SSH_KEY_PATH"
    else
        warn "Not an SSH public key: $ADMIN_SSH_KEY_PATH"
    fi
elif [[ -n "$ADMIN_SSH_KEY_PATH" ]]; then
    warn "Admin SSH key not found: $ADMIN_SSH_KEY_PATH - password auth remains active"
fi

if [[ -n "$WIFI_SSID" && "$WIFI_SECURITY" != "open" && -z "$WIFI_PASSWORD" ]]; then
    WIFI_PASSWORD=$(read_secure "WiFi password for '$WIFI_SSID'")
fi

out_file="$BOOT_MOUNT/provision.conf"
step "Writing provision.conf to $out_file..."

[[ -n "$ADMIN_SSH_KEY" ]] && admin_line="ADMIN_SSH_KEY='$ADMIN_SSH_KEY'" || admin_line="ADMIN_SSH_KEY="
[[ -n "$WIFI_PASSWORD" ]] && wifi_pass_line="WIFI_PASSWORD='$WIFI_PASSWORD'" || wifi_pass_line="WIFI_PASSWORD="

{
    printf '# provision.conf - First-boot configuration for inventory client station\n'
    printf '# Written %s by provision-image.sh\n' "$(date '+%Y-%m-%d %H:%M')"
    printf '#\n'
    printf '# Sensitive fields are zeroed automatically after successful first boot.\n'
    printf '\n'
    printf '# REQUIRED\n'
    printf 'REGISTRATION_SECRET=%s\n' "$REGISTRATION_SECRET"
    printf 'SERVER_URL=%s\n' "$SERVER_URL"
    printf 'DEPLOY_KEY_B64=%s\n' "$DEPLOY_KEY_B64"
    printf '\n'
    printf '# OPTIONAL - Admin SSH public key (enables passwordless SSH, disables password auth)\n'
    printf '%s\n' "$admin_line"
    printf '\n'
    printf '# OPTIONAL - WiFi (leave blank for Ethernet-only)\n'
    printf 'WIFI_SSID=%s\n' "$WIFI_SSID"
    printf '%s\n' "$wifi_pass_line"
    printf 'WIFI_COUNTRY=%s\n' "$WIFI_COUNTRY"
    printf '\n'
    printf '# OPTIONAL - Static IP (leave blank for DHCP)\n'
    printf 'STATIC_IP=%s\n' "$STATIC_IP"
    printf 'STATIC_GATEWAY=%s\n' "$STATIC_GATEWAY"
    printf 'STATIC_PREFIX=%s\n' "$STATIC_PREFIX"
    printf 'STATIC_DNS=%s\n' "$STATIC_DNS"
} > "$out_file"
ok "provision.conf written"

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n'
printf "${GREEN}================================================${NC}\n"
printf "${GREEN}  Done${NC}\n"
printf "${GREEN}================================================${NC}\n"
printf '\n'
if $FULL_MODE; then
    printf "${GRAY}  The SD card is ready. Safely eject it, then:${NC}\n"
    printf "${GRAY}  1. Insert into the Pi and power on${NC}\n"
    printf "${GRAY}  2. Boot 1: firstrun.sh runs, Pi reboots automatically (~1 min)${NC}\n"
    printf "${GRAY}  3. Boot 2: first_boot.sh runs - provisioning + registration (~5 min)${NC}\n"
    printf "${GRAY}  4. Accept the station at: %s/admin/clients${NC}\n" "$SERVER_URL"
    printf "${GRAY}  5. Monitor: ssh %s@<pi-ip>  then: tail -f ~/first-boot.log${NC}\n" "$PI_USERNAME"
else
    printf "${GRAY}  Safely eject the SD card, insert into the Pi, and power on.${NC}\n"
    printf "${GRAY}  first_boot.sh runs on the next boot (~5 min).${NC}\n"
    printf "${GRAY}  Accept the station at: %s/admin/clients${NC}\n" "$SERVER_URL"
fi
printf '\n'
