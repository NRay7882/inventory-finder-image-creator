"""Tests for provision-image scripts and bundled support files."""

import stat
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CREATE_SH = REPO_ROOT / "create-image.sh"
STATION_CONF_EXAMPLE = REPO_ROOT / "station.conf.example"
FIRST_BOOT_SH = REPO_ROOT / "first_boot.sh"


# ═════════════════════════════════════════════════════════════════════
# station.conf.example
# ═════════════════════════════════════════════════════════════════════


class TestProvisionConfExample:
    """station.conf.example must define all required and optional fields."""

    def test_required_fields_present(self):
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("REGISTRATION_SECRET", "SERVER_URL", "GITHUB_PAT"):
            assert field in content, f"Required field {field} missing from station.conf.example"

    def test_admin_ssh_key_field_present(self):
        assert "ADMIN_SSH_KEY=" in STATION_CONF_EXAMPLE.read_text()

    def test_wifi_fields_present(self):
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("WIFI_SSID", "WIFI_PASSWORD", "WIFI_COUNTRY"):
            assert field in content, f"WiFi field {field} missing from station.conf.example"

    def test_static_ip_fields_present(self):
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("STATIC_IP", "STATIC_GATEWAY", "STATIC_PREFIX", "STATIC_DNS"):
            assert field in content, f"Static IP field {field} missing from station.conf.example"

    def test_required_fields_are_blank(self):
        """Template must ship with empty values - no accidental secrets committed."""
        content = STATION_CONF_EXAMPLE.read_text()
        for field in ("REGISTRATION_SECRET", "GITHUB_PAT"):
            assert f"{field}=\n" in content or f"{field}=" in content, (
                f"{field} in station.conf.example must have a blank value"
            )


# ═════════════════════════════════════════════════════════════════════
# first_boot.sh
# ═════════════════════════════════════════════════════════════════════


class TestFirstBootSh:
    """first_boot.sh is present, executable, and syntactically valid."""

    def test_file_exists(self):
        assert FIRST_BOOT_SH.exists(), "first_boot.sh not found in repo root"

    @pytest.mark.skipif(sys.platform == "win32", reason="file mode bits not meaningful on Windows")
    def test_file_is_executable(self):
        assert FIRST_BOOT_SH.stat().st_mode & stat.S_IXUSR, "first_boot.sh is not executable"

    @pytest.mark.bash
    def test_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(FIRST_BOOT_SH)],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"first_boot.sh syntax error:\n{result.stderr}"

    def test_provision_conf_path_referenced(self):
        """first_boot.sh must read from the standard station.conf location."""
        assert "/boot/firmware/station.conf" in FIRST_BOOT_SH.read_text()

    def test_references_bundled_path_not_scripts_subdir(self):
        """first_boot.sh in the image creator should not reference client/scripts/."""
        content = FIRST_BOOT_SH.read_text()
        assert "client/scripts/first_boot.sh" not in content, (
            "first_boot.sh comment still references client/scripts/ path from inventory-finder repo"
        )


# ═════════════════════════════════════════════════════════════════════
# create-image.sh
# ═════════════════════════════════════════════════════════════════════


@pytest.mark.bash
class TestProvisionImageShHelp:
    """create-image.sh --help and error handling."""

    def test_help_exits_zero(self):
        result = subprocess.run(
            ["bash", str(CREATE_SH), "--help"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0

    def test_help_contains_key_options(self):
        result = subprocess.run(
            ["bash", str(CREATE_SH), "--help"],
            capture_output=True, text=True,
        )
        for option in ("--image-path", "--boot-mount", "--server-url", "--github-pat", "--wifi-ssid"):
            assert option in result.stdout, f"--help output missing option: {option}"

    def test_unknown_option_fails(self):
        result = subprocess.run(
            ["bash", str(CREATE_SH), "--no-such-option"],
            capture_output=True, text=True,
        )
        assert result.returncode != 0

    def test_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(CREATE_SH)],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"create-image.sh syntax error:\n{result.stderr}"


@pytest.mark.bash
class TestProvisionImageShPath:
    """create-image.sh references the bundled first_boot.sh, not a parent scripts/ dir."""

    def test_first_boot_path_is_local(self):
        content = CREATE_SH.read_text()
        assert '../scripts/first_boot.sh' not in content, (
            "create-image.sh still references ../scripts/first_boot.sh - should use $SCRIPT_DIR/first_boot.sh"
        )

    def test_first_boot_path_in_script_dir(self):
        assert "$SCRIPT_DIR/first_boot.sh" in CREATE_SH.read_text()


@pytest.mark.bash
class TestProvisionOnly:
    """create-image.sh provision-only mode writes a valid station.conf."""

    def test_writes_provision_conf(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text(
            "console=serial0,115200 root=/dev/mmcblk0p2 rootfstype=ext4\n"
        )

        result = subprocess.run(
            [
                "bash", str(CREATE_SH),
                "--boot-mount", str(boot),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "test-secret-abc",
                "--github-pat", "ghp_testtoken123",
                "--admin-ssh-key", "",
            ],
            capture_output=True, text=True, timeout=30,
        )
        assert result.returncode == 0, (
            f"create-image.sh failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
        assert (boot / "station.conf").exists(), "station.conf was not written to boot mount"

    def test_provision_conf_contains_required_fields(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("console=serial0,115200 root=/dev/mmcblk0p2\n")

        subprocess.run(
            [
                "bash", str(CREATE_SH),
                "--boot-mount", str(boot),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "my-test-secret",
                "--github-pat", "ghp_testtoken123",
                "--admin-ssh-key", "",
            ],
            capture_output=True, text=True, timeout=30,
        )
        conf_text = (boot / "station.conf").read_text()
        assert "REGISTRATION_SECRET=my-test-secret" in conf_text
        assert "SERVER_URL=http://192.168.1.100:8000" in conf_text
        assert "GITHUB_PAT=" in conf_text

    def test_nonexistent_boot_mount_fails(self, tmp_path):
        result = subprocess.run(
            [
                "bash", str(CREATE_SH),
                "--boot-mount", str(tmp_path / "nonexistent"),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "test",
                "--github-pat", "ghp_testtoken123",
            ],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode != 0

    def test_missing_github_pat_fails(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        result = subprocess.run(
            [
                "bash", str(CREATE_SH),
                "--boot-mount", str(boot),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "test",
                "--github-pat", "",
            ],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode != 0
