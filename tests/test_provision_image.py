"""Tests for provision-image scripts and bundled support files."""

import stat
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PROVISION_SH = REPO_ROOT / "provision-image.sh"
PROVISION_CONF_EXAMPLE = REPO_ROOT / "provision.conf.example"
FIRST_BOOT_SH = REPO_ROOT / "first_boot.sh"


# ═════════════════════════════════════════════════════════════════════
# provision.conf.example
# ═════════════════════════════════════════════════════════════════════


class TestProvisionConfExample:
    """provision.conf.example must define all required and optional fields."""

    def test_required_fields_present(self):
        content = PROVISION_CONF_EXAMPLE.read_text()
        for field in ("REGISTRATION_SECRET", "SERVER_URL", "DEPLOY_KEY_B64"):
            assert field in content, f"Required field {field} missing from provision.conf.example"

    def test_admin_ssh_key_field_present(self):
        assert "ADMIN_SSH_KEY=" in PROVISION_CONF_EXAMPLE.read_text()

    def test_wifi_fields_present(self):
        content = PROVISION_CONF_EXAMPLE.read_text()
        for field in ("WIFI_SSID", "WIFI_PASSWORD", "WIFI_COUNTRY"):
            assert field in content, f"WiFi field {field} missing from provision.conf.example"

    def test_static_ip_fields_present(self):
        content = PROVISION_CONF_EXAMPLE.read_text()
        for field in ("STATIC_IP", "STATIC_GATEWAY", "STATIC_PREFIX", "STATIC_DNS"):
            assert field in content, f"Static IP field {field} missing from provision.conf.example"

    def test_required_fields_are_blank(self):
        """Template must ship with empty values - no accidental secrets committed."""
        content = PROVISION_CONF_EXAMPLE.read_text()
        for field in ("REGISTRATION_SECRET", "DEPLOY_KEY_B64"):
            assert f"{field}=\n" in content or f"{field}=" in content, (
                f"{field} in provision.conf.example must have a blank value"
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
        """first_boot.sh must read from the standard provision.conf location."""
        assert "/boot/firmware/provision.conf" in FIRST_BOOT_SH.read_text()

    def test_references_bundled_path_not_scripts_subdir(self):
        """first_boot.sh in the image creator should not reference client/scripts/."""
        content = FIRST_BOOT_SH.read_text()
        assert "client/scripts/first_boot.sh" not in content, (
            "first_boot.sh comment still references client/scripts/ path from inventory-finder repo"
        )


# ═════════════════════════════════════════════════════════════════════
# provision-image.sh
# ═════════════════════════════════════════════════════════════════════


@pytest.mark.bash
class TestProvisionImageShHelp:
    """provision-image.sh --help and error handling."""

    def test_help_exits_zero(self):
        result = subprocess.run(
            ["bash", str(PROVISION_SH), "--help"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0

    def test_help_contains_key_options(self):
        result = subprocess.run(
            ["bash", str(PROVISION_SH), "--help"],
            capture_output=True, text=True,
        )
        for option in ("--image-path", "--boot-mount", "--server-url", "--deploy-key", "--wifi-ssid"):
            assert option in result.stdout, f"--help output missing option: {option}"

    def test_unknown_option_fails(self):
        result = subprocess.run(
            ["bash", str(PROVISION_SH), "--no-such-option"],
            capture_output=True, text=True,
        )
        assert result.returncode != 0

    def test_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(PROVISION_SH)],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"provision-image.sh syntax error:\n{result.stderr}"


@pytest.mark.bash
class TestProvisionImageShPath:
    """provision-image.sh references the bundled first_boot.sh, not a parent scripts/ dir."""

    def test_first_boot_path_is_local(self):
        content = PROVISION_SH.read_text()
        assert '../scripts/first_boot.sh' not in content, (
            "provision-image.sh still references ../scripts/first_boot.sh - should use $SCRIPT_DIR/first_boot.sh"
        )

    def test_first_boot_path_in_script_dir(self):
        assert "$SCRIPT_DIR/first_boot.sh" in PROVISION_SH.read_text()


@pytest.mark.bash
class TestProvisionOnly:
    """provision-image.sh provision-only mode writes a valid provision.conf."""

    @staticmethod
    def _fake_deploy_key(tmp_path: Path) -> Path:
        key_file = tmp_path / "fake_deploy_key"
        key_file.write_text(
            "-----BEGIN OPENSSH PRIVATE KEY-----\nZmFrZWtleWZha2VrZXlmYWtla2V5\n-----END OPENSSH PRIVATE KEY-----\n"
        )
        return key_file

    def test_writes_provision_conf(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text(
            "console=serial0,115200 root=/dev/mmcblk0p2 rootfstype=ext4\n"
        )
        key = self._fake_deploy_key(tmp_path)

        result = subprocess.run(
            [
                "bash", str(PROVISION_SH),
                "--boot-mount", str(boot),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "test-secret-abc",
                "--deploy-key", str(key),
                "--admin-ssh-key", "",
            ],
            capture_output=True, text=True, timeout=30,
        )
        assert result.returncode == 0, (
            f"provision-image.sh failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
        assert (boot / "provision.conf").exists(), "provision.conf was not written to boot mount"

    def test_provision_conf_contains_required_fields(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("console=serial0,115200 root=/dev/mmcblk0p2\n")
        key = self._fake_deploy_key(tmp_path)

        subprocess.run(
            [
                "bash", str(PROVISION_SH),
                "--boot-mount", str(boot),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "my-test-secret",
                "--deploy-key", str(key),
                "--admin-ssh-key", "",
            ],
            capture_output=True, text=True, timeout=30,
        )
        conf_text = (boot / "provision.conf").read_text()
        assert "REGISTRATION_SECRET=my-test-secret" in conf_text
        assert "SERVER_URL=http://192.168.1.100:8000" in conf_text
        assert "DEPLOY_KEY_B64=" in conf_text

    def test_nonexistent_boot_mount_fails(self, tmp_path):
        key = self._fake_deploy_key(tmp_path)
        result = subprocess.run(
            [
                "bash", str(PROVISION_SH),
                "--boot-mount", str(tmp_path / "nonexistent"),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "test",
                "--deploy-key", str(key),
            ],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode != 0

    def test_missing_deploy_key_fails(self, tmp_path):
        boot = tmp_path / "bootfs"
        boot.mkdir()
        (boot / "cmdline.txt").write_text("root=/dev/mmcblk0p2\n")
        result = subprocess.run(
            [
                "bash", str(PROVISION_SH),
                "--boot-mount", str(boot),
                "--server-url", "http://192.168.1.100:8000",
                "--registration-secret", "test",
                "--deploy-key", str(tmp_path / "no_such_key"),
            ],
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode != 0
