#!/usr/bin/python3
"""Check cloud/metal policy with Debian's actual APT parser and origin matcher."""

import importlib.machinery
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

import apt_pkg


loader = importlib.machinery.SourceFileLoader(
    "unattended_upgrade", "/usr/bin/unattended-upgrade"
)
spec = importlib.util.spec_from_loader(loader.name, loader)
upgrades = importlib.util.module_from_spec(spec)
loader.exec_module(upgrades)
config = Path(__file__).resolve().parents[1] / "config/files/etc/apt/apt.conf.d"


def origin(**changes):
    fields = dict(
        origin="Debian", label="Debian", codename="trixie",
        archive="stable", component="main", site="deb.debian.org",
    )
    fields.update(changes)
    return SimpleNamespace(**fields)


class UpdatePolicy(unittest.TestCase):
    def load_policy(self, metal=False):
        apt_pkg.config.clear("Unattended-Upgrade")
        apt_pkg.config.clear("APT::Periodic")
        apt_pkg.read_config_file(
            apt_pkg.config, "/etc/apt/apt.conf.d/50unattended-upgrades"
        )
        apt_pkg.read_config_file(
            apt_pkg.config, str(config / "52-frithuz-unattended-upgrades/HARDEN")
        )
        if metal:
            apt_pkg.read_config_file(
                apt_pkg.config, str(config / "53-frithuz-unattended-backports/METAL")
            )
        return upgrades.get_allowed_origins()

    def test_origin_coverage(self):
        docker = dict(
            origin="Docker", label="Docker CE", codename="",
            archive="trixie", component="stable", site="download.docker.com",
        )
        nodesource = dict(
            origin=". nodistro", label=". nodistro", codename="nodistro",
            archive="nodistro", component="main", site="deb.nodesource.com",
        )
        cases = [
            (True, origin()),
            (True, origin(codename="trixie-security", label="Debian-Security")),
            (True, origin(codename="trixie", label="Debian-Security")),
            (True, origin(codename="trixie-updates")),
            (True, origin(**docker)),
            (True, origin(**nodesource)),
            (False, origin(codename="forky")),
            (False, origin(codename="forky-security", label="Debian-Security")),
            (False, origin(codename="trixie-proposed-updates")),
            (False, origin(**{**docker, "archive": "forky"})),
            (False, origin(**{**docker, "component": "test"})),
            (False, origin(**{**docker, "site": "unrelated.example"})),
            (False, origin(**{**nodesource, "site": "unrelated.example"})),
            (False, origin(**{**nodesource, "archive": "other"})),
            (False, origin(origin="Unrelated", label="Unrelated")),
        ]
        for metal in (False, True):
            allowed = self.load_policy(metal)
            for expected, repository in cases:
                with self.subTest(metal=metal, repository=vars(repository)):
                    self.assertEqual(
                        upgrades.is_allowed_origin(repository, allowed), expected
                    )

    def test_backports_only_on_metal(self):
        for metal in (False, True):
            allowed = self.load_policy(metal)
            for codename in ("trixie-backports", "forky-backports"):
                repository = origin(
                    origin="Debian Backports", label="Debian Backports",
                    codename=codename, archive="stable-backports",
                )
                with self.subTest(metal=metal, codename=codename):
                    self.assertEqual(
                        upgrades.is_allowed_origin(repository, allowed),
                        metal and codename == "trixie-backports",
                    )

    def test_daily_updates_and_manual_reboots(self):
        for metal in (False, True):
            self.load_policy(metal)
            for key in ("Enable", "Update-Package-Lists", "Unattended-Upgrade"):
                with self.subTest(metal=metal, key=key):
                    self.assertEqual(apt_pkg.config.find_i("APT::Periodic::" + key), 1)
            self.assertFalse(
                apt_pkg.config.find_b("Unattended-Upgrade::Automatic-Reboot", True)
            )


if __name__ == "__main__":
    unittest.main()
