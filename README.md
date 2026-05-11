# inventory-finder-image-creator

SD card preparation tool for deploying inventory-finder stations on Raspberry Pi.

Handles the full workflow - flash a base OS image, customise it, and write `station.conf` to the boot partition - without opening Raspberry Pi Imager manually. Works with the private `inventory-finder` repository.

## How it works

The Pi image itself contains no secrets. Before inserting the SD card you place a `station.conf` file on its FAT32 boot partition (readable from any OS without special tools). On first boot the Pi reads this file, configures GitHub credentials, clones the inventory-finder repo, runs full provisioning, and registers with the server. Sensitive fields in `station.conf` are zeroed automatically after a successful setup.

**Boot sequence:**

| Boot | What happens | Duration |
|------|-------------|----------|
| Boot 1 | `firstrun.sh` sets hostname, user account, SSH, WiFi; Pi reboots | ~1 min |
| Boot 2 | `first_boot.sh` installs software, registers with server, starts VPN | ~5-10 min |

After Boot 2, accept the station in the inventory-finder admin UI at `<SERVER_URL>/admin/clients`.

## Prerequisites

Run `setup.ps1` (Windows) or `setup.sh` (Mac/Linux) once to check and install prerequisites:

**Windows:**
```powershell
.\setup.ps1
```

**Mac/Linux:**
```bash
chmod +x setup.sh
./setup.sh
```

What gets checked:
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) - required for full mode (flash + customise); setup scripts can install it automatically via winget or Homebrew
- Admin SSH public key at `~/.ssh/id_ed25519.pub` (optional - enables passwordless SSH on the Pi)

Use **Raspberry Pi OS Lite (64-bit), Trixie/Debian 13** as the base image, available from [raspberrypi.com/software/operating-systems](https://www.raspberrypi.com/software/operating-systems/).

## Usage

### Windows - create-image.ps1

Must be run as Administrator (rpi-imager requires elevation to write to a disk).

**Full mode** - flash, customise, and write station.conf:
```powershell
.\create-image.ps1 -ImagePath "C:\images\raspios-trixie-arm64-lite.img.xz" -WifiSsid "IoTLAN-5G"
```

Pass a directory to `-ImagePath` and the script will find the `.img.xz` inside it automatically. If more than one is found, it prompts you to choose (newest first).

**Provision-only** - write station.conf to an already-flashed card:
```powershell
.\create-image.ps1 -WifiSsid "IoTLAN-5G"
```

Run `Get-Help .\create-image.ps1 -Full` for all parameters.

**Saved defaults:** After each successful run the script saves all settings to `.create-image.defaults.json` (gitignored). On the next run, non-sensitive values are restored automatically; sensitive values (Pi password, WiFi password, GitHub PAT, registration secret) are stored DPAPI-encrypted and shown as `[saved - Enter to keep]` at the prompt. Pass any parameter explicitly to override and update the saved value.

**Key parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ImagePath` | *(omit for provision-only)* | `.img`/`.img.xz` file **or directory** containing one |
| `-Hostname` | `rpi5-inventory` | Pi hostname |
| `-Username` | `rpi5` | OS user account to create |
| `-WifiSsid` | *(blank = Ethernet-only)* | WiFi network name |
| `-ServerUrl` | *(from .env or prompt)* | Server base URL, e.g. `http://192.168.2.100:8000` |
| `-GithubPat` | *(prompted)* | GitHub PAT with read-only Contents access to inventory-finder |
| `-AdminSshKeyPath` | `~\.ssh\id_ed25519.pub` | Admin public key (pass `""` to skip) |
| `-StaticIp` | *(blank = DHCP)* | Optional static IP for the Pi |
| `-DiskNumber` | *(auto-detected)* | Override SD card disk number from `Get-Disk` |

---

### Mac/Linux - create-image.sh

**Full mode:**
```bash
./create-image.sh --image-path ~/Downloads/raspios-trixie-arm64-lite.img.xz --wifi-ssid "IoTLAN-5G"
```

The script auto-detects the SD card from removable block devices and asks for confirmation before erasing. After flashing it ejects and prompts you to re-insert.

**Provision-only:**
```bash
./create-image.sh --wifi-ssid "IoTLAN-5G"
```

The boot partition is auto-detected by looking for a FAT volume containing `cmdline.txt`. Pass `--boot-mount PATH` to override.

Run `./create-image.sh --help` for the full option list.

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--image-path PATH` | *(omit for provision-only)* | `.img` or `.img.xz` file to flash |
| `--disk DEVICE` | *(auto-detected)* | SD card device, e.g. `/dev/disk4` or `/dev/sdb` |
| `--boot-mount PATH` | *(auto-detected)* | Boot partition mount point |
| `--hostname NAME` | `rpi5-inventory` | Pi hostname |
| `--username NAME` | `rpi5` | OS user account to create |
| `--wifi-ssid SSID` | *(blank = Ethernet-only)* | WiFi network name |
| `--server-url URL` | *(prompted)* | Server base URL |
| `--github-pat TOKEN` | *(prompted)* | GitHub PAT with read-only Contents access to inventory-finder |
| `--admin-ssh-key PATH` | `~/.ssh/id_ed25519.pub` | Admin public key (pass `""` to skip) |
| `--static-ip IP` | *(blank = DHCP)* | Optional static IP for the Pi |

---

## station.conf

Written to the SD card's `bootfs` partition by both scripts. See `station.conf.example` for the full template.

**Required fields:**
```ini
REGISTRATION_SECRET=<value from server .env>
SERVER_URL=http://192.168.2.100:8000
GITHUB_PAT=<fine-grained PAT with read-only Contents access to inventory-finder>
```

The scripts read `REGISTRATION_SECRET` from `server/.env` automatically if the inventory-finder repo is cloned alongside this one (i.e. at `../inventory-finder/server/.env`). Otherwise they prompt securely.

The `GITHUB_PAT` is a GitHub fine-grained token scoped to `inventory-finder` with Contents: Read-only. It is prompted securely during image creation. See the inventory-finder server README for token creation and rotation instructions.

## Customisation

`first_boot.sh` contains the private repo URL used when cloning onto the Pi:
```bash
GITHUB_REPO="https://github.com/YourOrg/inventory-finder.git"
```

If you fork `inventory-finder`, update this URL in `first_boot.sh` to point to your fork before preparing images. The `GITHUB_PAT` you supply in `station.conf` must have Contents read access to this repository.

## Testing

Tests run on Linux or macOS. They are skipped automatically on Windows.

```bash
# Install uv if not already: https://astral.sh/uv
uv run --group test pytest
uv run --group test pytest -v
```

## Files

| File | Purpose |
|------|---------|
| `create-image.ps1` | Windows: flash SD card and write station.conf |
| `create-image.sh` | Mac/Linux: flash SD card and write station.conf |
| `first_boot.sh` | First-boot script written to the boot partition during image prep |
| `station.conf.example` | Template for the boot-partition config file |
| `setup.ps1` | Windows: check and install prerequisites |
| `setup.sh` | Mac/Linux: check and install prerequisites |
