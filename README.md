# deb-test: one FAI config, cloud images + metal installer

A sample [FAI](https://fai-project.org) config space for Debian 13 (trixie) servers
built to the **CIS Debian Linux Benchmark, Level 1 - Server**. It builds two things
from the same config:

| Artifact | Built with | Used for |
|---|---|---|
| `build/cloud-<arch>.qcow2` | `fai-diskimage` | AWS/GCE/Azure/Proxmox/libvirt |
| `build/metal-<arch>.iso` | `fai-make-nfsroot` + `fai-cd` | USB/ISO that installs a physical server; downloads packages during the install |

`<arch>` is `amd64` or `arm64`. Each architecture is built **natively** on a host of that
architecture: no emulation, no cross-building. `make` defaults to the build host's
architecture and refuses a mismatched `ARCH=`. CI builds both on GitHub's x64 and Arm64
runners (see [CI](#ci-github-actions)).

The split of responsibilities is the same on every machine:

- **FAI decides what's installed.** The package set comes from `config/package_config/`
  only, and the build fails if the result doesn't match it.
- **cloud-init does the configuration** on first boot: users, SSH keys, hostname and
  anything else in `config/cloud-init/user-data`. Clouds get that file as instance user
  data. Metal installs get it baked in as a NoCloud seed.
- **One login everywhere:** user `jonathan`, SSH keys only, imported from GitHub
  (`gh:garbee`, i.e. https://github.com/garbee.keys) on first boot. Root is locked and
  there are no passwords.

## Compliance: CIS Level 1 Server

The `HARDEN` class applies the CIS Debian Level 1 Server controls, and **every build is
checked against them**. `cis-check` is installed on every machine
(`/usr/local/sbin/cis-check`). `scripts/LAST/92-cis-check` runs it against the
finished image or install, and any FAIL stops the build. Run it again on a live machine at
any time:

```sh
sudo cis-check            # every control: PASS / FAIL / EXCEPT / SKIP / MANUAL, exit 1 on any FAIL
sudo cis-check --quiet    # only what needs attention
```

What it covers, by benchmark section:

| Section | Applied by | Notes |
|---|---|---|
| 1.1 filesystems | `files/etc/modprobe.d/90-hardening.conf`, `disk_config/METAL_EFI`, `HARDEN/10-config` | cramfs/freevxfs/hfs/hfsplus/jffs2 disabled (usb-storage: exception). `/tmp` and `/dev/shm` are nodev,nosuid,noexec. Metal also has separate `/home`, `/var`, `/var/log`, `/var/log/audit` (Level 2, with the right options) |
| 1.3 AppArmor | `package_config/HARDEN`, `files/etc/default/grub.d/40-cis.cfg` | enabled on the kernel command line |
| 1.4 bootloader | `HARDEN/50-grub-password` | grub superuser password; entries stay `--unrestricted` so machines boot unattended. `grub.cfg` 0600 |
| 1.5 process hardening | `files/etc/sysctl.d/90-hardening.conf` | ASLR, ptrace scope, no core dumps |
| 1.6 banners | `files/etc/{motd,issue,issue.net}` | legal notice, no OS details |
| 2.x services | `package_config/HARDEN` (removals), `HARDEN/40-services` | no server daemons or insecure clients; chrony only; cron locked down; rsync daemon masked; no MTA |
| 3.3 network | `files/etc/sysctl.d/90-hardening.conf` | no forwarding/redirects/source routing, rp_filter, syncookies, **no IPv6 router advertisements** |
| 4.3 firewall | `files/etc/nftables.conf` | nftables only, default deny on input and forward, inbound SSH only. Outbound allowed (exception) |
| 5.1 SSH | `files/etc/ssh/sshd_config.d/10-cis.conf` | `AllowUsers jonathan`, strong ciphers/kex/MACs only, no forwarding, banner, limits |
| 5.2 sudo / su | `DEBIAN/30-sudo-rs`, `files/etc/sudoers.d/50-cis`, `HARDEN/20-pam` | `sudo` is sudo-rs; members of `sudo` keep their PATH, which includes the sbin directories for every user. pty, timeout, commands logged to the journal (no log file: exception). `su` limited to the empty `sugroup` |
| 5.3 PAM | `HARDEN/20-pam`, `files/usr/share/pam-configs/*` | faillock, pwquality, pwhistory, no `nullok` (Debian's `unix` profile is dpkg-diverted so upgrades can't put it back) |
| 5.4 accounts | `HARDEN/30-accounts`, `files/etc/profile.d/50-cis.sh` | password ageing defaults, yescrypt, inactive lock, umask 027, 15-min shell timeout |
| 6.1 logging | `files/etc/systemd/journald.conf.d/{50-cis,syslog}.conf`, `files/etc/tmpfiles.d/cis-logs.conf` | journald only, persistent, compressed. Log files not world-readable (also re-applied at boot) |
| 6.3 integrity | `aide`, `aide-firstboot-init.service` | AIDE baseline built on first boot (after cloud-init), daily check timer, audit tools protected |
| 7.x files & accounts | `HARDEN/30-accounts`, checks only | account file permissions, no world-writable/unowned files, account sanity |

**Accepted exceptions:** `config/files/etc/cis-check/exceptions/HARDEN` lists deliberate
deviations from the benchmark, each with its reason. `cis-check` still runs those controls
but reports them as `EXCEPT` instead of FAIL, so the deviation is visible in every report.
Delete a line to enforce that control again.

| Control | Decision |
|---|---|
| 1.1.1.9 usb-storage disabled | USB storage stays enabled, for maintenance |
| 4.3.8 default deny on **output** | outbound traffic is allowed. Input and forward remain default-deny and are still enforced |
| 5.2.3 sudo log file | sudo-rs has no `logfile=` option. It logs every command to the journal instead |

**Site decisions** (reported as MANUAL, never FAIL, until you act on them):

| Control | What to do |
|---|---|
| 6.1.2.1.2/3 send logs to a log server | none for now. When there is one, set `JOURNAL_UPLOAD_URL` in `config/class/HARDEN.var` |
| 1.4.1 grub password you can actually use | see [Setting the GRUB password](#setting-the-grub-password). Default: a random password per build that nobody knows; recovery then means rescue media |
| 5.2.4 sudo password | Level 2 only. `jonathan` uses passwordless sudo because the account has no password |
| 1.2.x, 2.1.22, 4.3.7, 7.1.13 | human review by nature: repositories/keys, listening services, outbound policy, SUID files. `cis-check` prints what to look at |

### Setting the GRUB password

The GRUB password stops anyone at the console (keyboard, IPMI/BMC, or a cloud serial
console) from editing a boot entry or opening the GRUB command line. Normal boots never
ask for it. By default each build gets a random password that nobody knows. Set your own
if you want to be able to fix a machine from the boot menu.

1. **Make a hash** on any Debian machine (the tool comes with `grub-common`):

   ```sh
   grub-mkpasswd-pbkdf2
   # Enter password:            <- choose a long one; store it in your password manager
   # Reenter password:
   # PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.4E1F...C2B7
   ```

2. **Save the hash** in `config/secrets/grub-password.hash`. That directory is gitignored,
   so the hash never reaches the (public) repository. It is also kept out of FAI
   variables, because FAI writes every variable into its logs.

   ```sh
   grub-mkpasswd-pbkdf2 | tee config/secrets/grub-password.hash   # the whole output is fine
   chmod 600 config/secrets/grub-password.hash
   ```

3. **Rebuild locally:** `sudo make cloud` and/or `sudo make metal-iso`. Every machine built
   from now on uses this password. The build fails if the file exists but has no
   `grub.pbkdf2.` hash in it. CI never has this file, so CI builds always get a random
   password. That's intended: CI artifacts of a public repository are downloadable.

4. **Use it:** at the GRUB menu press `e` (edit) or `c` (command line). The username is
   `grubadmin`, and the password is the one you chose in step 1.

**Machines that already exist** keep the password they were built with. To change one
in place:

```sh
sudo sed -i "s|password_pbkdf2 grubadmin .*'|password_pbkdf2 grubadmin grub.pbkdf2.sha512.10000.4E1F...C2B7'|" \
    /etc/grub.d/01_cis_password
sudo update-grub                     # grub.cfg keeps its 0600 mode
sudo grep -c password_pbkdf2 /boot/grub/grub.cfg   # 1
```

Notes:
- **The hash is not the password,** but it can be brute-forced offline, so use a long
  random password. Images and ISOs built with it contain it in `grub.cfg`, so don't
  publish those builds.
- **One password for every machine** built from this config. For per-machine passwords,
  change them in place as above.
- **To go back to an unknown random password,** delete `config/secrets/grub-password.hash` and rebuild.
- **The password only guards the GRUB menu.** Booting other media is controlled by a
  firmware (BIOS/UEFI) password and Secure Boot, and reading a removed disk can only be
  prevented by disk encryption.

**Things to know:**
- **`cis-check` is our own implementation of the benchmark's automatable checks,** not
  CIS-CAT. Its IDs follow the CIS Debian Linux 12 Benchmark v1.1.0 numbering; the Debian 13
  benchmark keeps the same structure, but confirm against the copy you're audited on. For a
  formal audit, also run CIS-CAT (or your auditor's scanner) against a built machine.
- **IPv6:** router advertisements are off (3.3.11), so SLAAC doesn't work. Configure IPv6
  statically or via DHCPv6/cloud-init if you need it.
- **Drift:** controls can drift as the system changes, e.g. a new service writing
  world-readable logs. Run `sudo cis-check` after changes, or from a timer/monitoring.

## Package consistency

| Guarantee | How |
|---|---|
| Every machine has the packages you listed, and none you removed | `scripts/LAST/90-verify-packages` checks the installed system against `package_config/` and **fails the build** on any mismatch. Normally FAI only *warns* about package names it can't find (typos, packages renamed or dropped from the release) and carries on. |
| You can see the exact list before building | `make packages` (no root): the shared set, cloud-only and metal-only, and which class file each package comes from |
| Every build/install resolves to the **same versions** | Optional: set `APT_SNAPSHOT` in `config/class/SERVER.var` to a snapshot.debian.org timestamp. Every install is then frozen to that moment until you bump it on purpose. Afterwards machines are switched back to the live mirrors for security updates. |
| You can prove two machines match | Every machine records `/var/lib/fai-build/packages.tsv` (package + version) and `build-info`. `test/compare-packages.sh` diffs any two. The cloud build also drops `build/cloud.packages.tsv`. |
| cloud-init doesn't add packages behind your back | `make check` rejects `packages:` / `package_upgrade:` / `apt:` in `user-data` |
| A failing script doesn't get ignored | `STOP_ON_ERROR=400` in `SERVER.var` (FAI's default lets configure-script errors through) |

Cloud and metal deliberately differ in a few packages (`make packages` lists them):
- **Cloud:** the cloud kernel, growroot and the guest agent.
- **Metal:** the full kernel, firmware, microcode, and RAID/SMART/IPMI tools.

Without `APT_SNAPSHOT`, versions drift with each build and each metal install
(whatever is current that day). Even with it, `unattended-upgrades` applies
security updates afterwards, which is usually what you want. The manifest shows
what each machine *started* with. Run `dpkg-query -W` on the machine for its
current state.

## Trying it

Everything below runs in local QEMU VMs. Nothing touches your real disks until you
write the ISO to a USB stick yourself.

### 0. Prerequisites

- **A Debian 13 (trixie) build host where you have root,** amd64 or arm64. It builds its
  own architecture. This can be your workstation, a VM, or let CI do it. The builds use loop devices and chroots, so they won't work
  in an unprivileged container.
- **About 6 GB free disk space,** mostly for the FAI nfsroot (`/srv/fai/nfsroot`)
  and the test disks.
- **Internet access** while building, and for the machines while they install.
- **KVM** (`/dev/kvm`) for usable test-VM speed: `sudo adduser $USER kvm`, then log
  in again. Without it, QEMU still works but is very slow.
- **Your SSH key on GitHub:** the VMs import `gh:garbee`'s keys on first boot, so the
  key you log in with must be one of https://github.com/garbee.keys. The VMs also need
  internet access for that (QEMU's user networking provides it).
- **A graphical session** for the metal installer step. The other steps use a
  serial console in your terminal.

No `sudo`? Run the `sudo make ...` steps as root instead (`su -`, then `cd` here).
The Makefile detects root.

### 1. Install the tooling, check the config

```sh
sudo apt install make        # only needed the first time
sudo make deps               # FAI, QEMU, OVMF, cloud-image-utils, xorriso, shellcheck, ...
make check                   # lint scripts + user-data, resolve the package lists (no root)
make packages                # see exactly what cloud and metal machines will get
```

### 2. Cloud image

```sh
sudo make cloud              # ~5-10 min -> build/cloud-<arch>.qcow2 + .packages.tsv + .cis-check.txt
make test-cloud              # boots it; the serial console takes over this terminal
```

`test-cloud` boots a throwaway copy of the image with `config/cloud-init/user-data`
as a NoCloud seed, the way a cloud provider would pass it. Each run starts from the
pristine image, like a fresh instance.

Wait for the `login:` prompt (cloud-init finishes about then), and in **another terminal**:

```sh
make ssh                     # = ssh -p 2222 jonathan@localhost, ignoring the VM's changing host key
```

To stop the VM, press `Ctrl-a` then `x` in the console terminal, or run `sudo poweroff` inside it.

If the build stops with `PACKAGE CHECK FAILED: <pkg> ...`, that package name doesn't
exist in the release, or something removed it. Fix `package_config/` and rebuild.
If it stops at `LAST/92-cis-check`, the FAIL lines it printed say which CIS control
broke. The full report is `cis-check.txt` in the FAI log dir.

If `make ssh` is refused, check `cloud-init status --long` on the console. The usual
cause is the GitHub key import failing, either because there's no network, or because
your local key isn't one of the keys on GitHub.

### 3. Metal installer ISO

```sh
sudo make metal-iso          # first run ~15 min (builds the nfsroot once) -> build/metal-<arch>.iso
make test-metal              # opens a QEMU window: the ISO plus a blank 32G NVMe disk
```

In the QEMU window:

1. In the boot menu, pick **"Client standalone installation - select installation type from menu"**.
2. Pick the **"Hardened server"** profile. ("Server (no hardening)" exists only for
   debugging and is not CIS compliant.)
3. Confirm the warning that the disk will be erased. FAI then partitions, downloads
   and installs packages, and configures the system. Watch the log scroll by.
4. When FAI reports that the installation has finished, close the QEMU window.

Then boot the installed disk (serial console in this terminal). cloud-init runs on
this first boot, creates `jonathan` and imports the GitHub keys. Log in from another terminal:

```sh
make boot-metal
make ssh                     # in a second terminal
```

### 4. Check what you got

Inside either VM:

```sh
sudo cis-check --quiet              # CIS Level 1 Server: only FAIL/MANUAL lines + summary
cat /var/lib/fai-build/cis-check-build.txt   # the full report from build time
cat /var/lib/fai-build/build-info   # classes, build date, apt snapshot
swapon --show                       # prints nothing: no swap, by policy
lsblk -f                            # metal: GPT + LVM with separate /var, /var/log, /tmp, ...
cloud-init status --long            # "done", and which datasource it used
cat ~/.ssh/authorized_keys          # the keys imported from github.com/garbee
systemctl --failed                  # ideally empty
sudo lynis audit system --quick     # a second opinion
```

Compare the two machines' package sets. Expect the cloud/metal differences that
`make packages` shows, plus their dependencies:

```sh
scp -P 2222 jonathan@localhost:/var/lib/fai-build/packages.tsv build/metal.packages.tsv   # while boot-metal runs
test/compare-packages.sh build/cloud-amd64.packages.tsv build/metal.packages.tsv
```

The build host keeps the FAI logs under `/var/log/fai/<hostname>/last/` (`cloud-amd64`
or `cloud-arm64` for the cloud image). Installed machines keep theirs in `/var/log/fai/`. If a build
fails, FAI prints which script failed, and `scripts.log` / `error.log` have the
details. `packages.expected` there is the resolved list the check used.

### 5. Real hardware and real clouds

**Metal:** write the ISO to a USB stick (check the device name with `lsblk` first:
this overwrites it):

```sh
sudo dd if=build/metal-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot the server from it in **UEFI** mode, with network access. **The installer wipes
the first disk it finds** (FAI's `disk1`). On a machine with several disks, make sure
that's the one you mean.

**Cloud:** convert to raw (`qemu-img convert -O raw build/cloud-amd64.qcow2 build/cloud-amd64.raw`)
and import it, e.g. AWS `import-snapshot` -> `register-image`, or `gcloud compute images create`.
When launching instances, pass `config/cloud-init/user-data` as the user data. The
provider's own SSH key mechanism works too.

### Starting over

```sh
make clean                   # removes build/ and the test VM disks (keeps /srv/fai/nfsroot and /srv/fai/etc)
```

After editing anything in `config/`, just rerun `sudo make cloud` / `sudo make metal-iso`.
The Makefile notices the change and rebuilds. Changes to `cloud-init/user-data` affect
the ISO (metal seeds come from it) and the tests, but not the cloud image.

## CI (GitHub Actions)

`.github/workflows/build.yml` runs on pushes to `main`, on pull requests, and by hand
(**Actions -> build -> Run workflow**):

| Job | Runner | What it does |
|---|---|---|
| `check` | `ubuntu-26.04` | `make check`; every package name checked against the real trixie archive for amd64 and arm64 (`test/check-package-names.sh`); expected package sets for both arches |
| `cloud (amd64)` | `ubuntu-26.04` (x64) | build `cloud-amd64.qcow2` natively, then `test/ci-boot-test.sh` |
| `cloud (arm64)` | `ubuntu-26.04-arm` (Arm64) | the same for `cloud-arm64.qcow2` |
| `compare` | `ubuntu-26.04` | the build-time manifest must equal what's installed after first boot, per arch |
| `metal (amd64/arm64)` | both | build `metal-<arch>.iso` natively, install from it unattended and boot the result (`test/ci-boot-test.sh build metal`) |

- **Build environment:** every build runs in a privileged `debian:trixie` container with
  the host's `/dev`, which FAI needs for loop devices and chroots. Docker pulls the
  runner's own architecture, so nothing is emulated.
- **The boot test:** boots the image headless and logs in as `jonathan` with a
  throwaway key it generates and adds to a copy of `user-data`. It requires cloud-init
  to finish and the running system to pass `cis-check`. The real `ssh_import_id: gh:garbee`
  still runs; if it can't import (GitHub rate-limits shared CI addresses), that's only a warning.
  Progress is logged as it goes: elapsed-time prefixes, a status line about once a
  minute while waiting, and the VM's serial console with a `[vm]` prefix. The run's
  summary page gets a table of how long each phase took.
- **The metal test** first installs from the ISO onto a blank 32G NVMe disk. It boots
  the ISO's own kernel and initrd straight from QEMU, using the arguments of the
  "Client standalone installation" boot entry without the profile menu and with
  `halt` added (FAI powers off when done). Without the menu, the classes come from
  `class/50-host-classes`, which picks the same ones as the "Hardened server" profile
  except `INSTALL` (which only shows the disk-wipe warning). It then boots the
  installed disk with a `cidata` seed drive carrying the test key. That seed's
  user-data replaces the one baked into the install. After that, it runs the same
  checks as the cloud test, plus: FAI reported no task errors, the hardened classes
  were used, the CIS mounts exist, and the install manifest matches what's installed.
  The GRUB menu and profile dialog themselves are not exercised. To run it locally:
  `ARCH=<arch> test/ci-boot-test.sh build metal`.
- **KVM:** the "Host facts" step prints whether `/dev/kvm` is available. x64 runners
  have it. If the Arm64 runner doesn't, its boot tests still run, but emulated, so they're
  much slower (the cloud job allows 150 minutes, the metal job 210).
- **Artifacts:** reports and FAI logs on every run, images on non-PR runs. All are kept for 1 day.
  Any signed-in GitHub user can download artifacts of a public repository; see below.
- **Action pins:** third-party actions are pinned to commit SHAs. To update, resolve the
  new tag with `git ls-remote https://github.com/actions/checkout refs/tags/vX.Y.Z` and
  replace the SHA and the comment.
- **Runner sizes:** Arm64 runners in *private* repositories are smaller (2 vCPU, 14 GB
  disk). Cloud builds fit; metal ISOs are tight.

### Releases

`.github/workflows/release.yml` runs only by hand (**Actions -> release -> Run workflow**).
The tag defaults to `date@<UTC date>/run@<run number>` (e.g. `date@2026-10-31/run@42`);
the optional `tag` input overrides it. It runs the whole `build` workflow on the selected branch,
then creates a **draft** release with `cloud-<arch>.qcow2`, `metal-<arch>.iso` and a
`SHA256SUMS` file for all of them. The workflow creates the tag on the built commit
before creating the draft; an existing tag is rejected. Review the draft and publish it.
Verify a download with `sha256sum -c --ignore-missing SHA256SUMS`.

## Publishing this repository

This repo is meant to be public. Here's what that exposes and what's kept out:

| Item | Public? | Notes |
|---|---|---|
| Everything under `config/` | yes | It describes the hardening, not secrets. Attackers learn your posture (e.g. the CIS exceptions), which is normal for public infrastructure code |
| Login name `jonathan`, GitHub user `garbee` | yes | Both are needed in the config. Knowing the username doesn't help without a key; root is locked and passwords are off |
| `config/secrets/` (GRUB hash) | **no** | gitignored, and never in an FAI variable (FAI logs all variables to `variables.log`) |
| CI images and ISOs | yes (to signed-in users) | Built without secrets (random GRUB password, no keys baked in, host keys and machine-id wiped). Don't upload builds made with `config/secrets/` anywhere public |
| CI logs and FAI logs | yes | Contain build variables and package lists, no secrets. Never add secrets as FAI variables or print them in scripts |

**Rules that keep it that way:**
- **No secrets in `user-data`.** It's committed, and on clouds the instance's user data
  is readable through the metadata service. Use it for configuration only.
- **No secrets in `class/*.var`.** FAI writes every variable to `variables.log`, which ends
  up in CI artifacts and in `/var/log/fai/` on every machine. Only `ROOTPW` and `USERPW`
  are masked. Pass secrets as files under `config/secrets/`, as the GRUB hash does.
- **Your GitHub account is the root of trust.** `ssh_import_id: gh:garbee` installs
  *every* key on that account onto each new server, which right now is 10 keys, including an
  older RSA one. Use 2FA, and remove keys you don't use any more from GitHub. A
  compromised GitHub account means SSH access to every machine built afterwards.
- **Workflow safety:** pull requests from forks run with a read-only token and no
  secrets, and this workflow uses none. If you ever add secrets, use them only in
  jobs that don't run for `pull_request`, and never in a privileged container that runs
  fork code.
- **Before the first push:** `git status --ignored` should list `config/secrets/*` and
  `build/` as ignored. Upstream FAI's example password hashes (`fai`) have been removed
  from `class/FAIBASE.var`, and the metal installer's own root password (also `fai`,
  from fai-server's `nfsroot.conf`) is locked at build time (see the Makefile).

## How FAI composes a machine: classes

Every host gets an ordered list of **classes**. Every directory in `config/`
holds files named after classes, and FAI uses the ones that match.
Later classes override earlier ones.

```
               DEBIAN  FAIBASE  SERVER  HARDEN  ┬ CLOUD  + CLOUD_EFI  + LAST   -> cloud-<arch>.qcow2
  (upstream FAI base)  (ours: shared by both)   └ METAL  + METAL_EFI  + LAST   -> metal-<arch>.iso
```

| Class | Origin | What it does |
|---|---|---|
| `DEBIAN`, `FAIBASE`, `GRUB_EFI` | upstream FAI example | Base OS, kernel, locales, bootloader |
| `SERVER` | **ours** | Server tools, cloud-init with the `jonathan` default user and GitHub key import, locked root, apt sources and the optional snapshot pin, no-swap check |
| `HARDEN` | **ours** | **CIS Level 1 Server** (see above), plus auditd and lynis |
| `CLOUD` | upstream + ours | cloud kernel, growroot, guest agent, serial console |
| `METAL` | **ours** | Firmware, microcode, LVM/mdadm/SMART/IPMI tools, serial console for IPMI SOL, CIS-style LVM layout, NoCloud seed for cloud-init |
| `LAST` | upstream + ours | Sanity checks, **package verification, CIS check**, manifest, final apt sources |

Leaving `HARDEN` out gives a non-compliant build. That's only useful for debugging,
and the ISO's menu has a profile for it (`config/class/server.profile`).

## Layout: where to change things

```
config/
  cloud-init/user-data     the ONE cloud-init config for every machine (GitHub key import, settings)
  package_config/<CLASS>   packages to install/remove: the package contract
  class/SERVER.var         timezone, APT_SNAPSHOT pin, STOP_ON_ERROR
  class/HARDEN.var         CIS site decisions (JOURNAL_UPLOAD_URL)
  secrets/                 gitignored: grub-password.hash (see "Setting the GRUB password")
  class/50-host-classes    hostname -> classes (metal installs without the menu)
  class/server.profile     the install menu shown by the ISO
  class/*.var              other per-class variables
  debconf/<CLASS>          preseeded debconf answers
  disk_config/<CLASS>      partitioning (METAL_EFI: GPT + LVM, separate /var /var/log /tmp ...)
  files/<path>/<CLASS>     files copied into the target with fcopy, e.g.
                           files/etc/ssh/sshd_config.d/10-cis.conf/HARDEN
  files/usr/local/sbin/cis-check/HARDEN   the CIS checker installed on every machine
  files/etc/cis-check/exceptions/HARDEN   accepted deviations from the benchmark, with reasons
  scripts/<CLASS>/NN-name  scripts run against the target ($ROOTCMD = chroot into it)
  bin/resolve-packages     package_config/ -> final package list (used by the check and `make packages`)
  hooks/                   run before FAI's built-in tasks (upstream defaults)
Makefile                   class lists for each artifact + build/test targets
test/qemu.sh               UEFI QEMU runner (user-data seed for cloud, blank NVMe disk for metal, unattended install when headless)
test/compare-packages.sh   diff two packages.tsv manifests
test/ci-boot-test.sh       headless boot test (cloud image, or unattended ISO install + boot): SSH login, cloud-init, cis-check, package drift
test/check-package-names.sh  package_config/ names vs. the Debian archive, per arch (network, no root)
.github/workflows/build.yml  CI: lint, then build + boot-test amd64 and arm64 natively
.github/workflows/release.yml  manual: build via build.yml, then a draft release with checksums
```

To **add a role** (e.g. `DOCKER`), create `package_config/DOCKER` (and `scripts/DOCKER/...`
or `files/.../DOCKER` if needed), then add `DOCKER` to `CLOUD_CLASSES` and/or the
metal profile. Run `make packages` to see the effect. Keep role *configuration* in
cloud-init if it varies per machine.

## Notes / next steps

- **Cloud class lists are explicit.** `fai-diskimage` gets them from the `Makefile`
  and does not run the `class/` scripts. Metal installs work the classes out at
  install time (the menu plus the `class/` scripts). `METAL_CLASSES` in the Makefile
  mirrors that result for `make packages`. Keep it in sync if you change the profile.
- **The package check covers what you list,** not their dependencies. Dependencies are
  pinned by `APT_SNAPSHOT` and recorded in the manifest.
- **snapshot.debian.org is slow** and rate-limits heavy use. If you build often or
  install many machines, run your own frozen mirror (`aptly` snapshots) and point
  `apt_base`/`apt_sec` in `SERVER.var` at it. The mechanism is the same.
- **Your own software:** create a metapackage, host it in an `aptly`/`reprepro` repo,
  and add it to `package_config/SERVER`. It gets the same check and manifest as
  everything else.
- **UEFI only**, on both arches. The amd64 ISO still boots in legacy BIOS mode (fai-cd
  always builds it that way), but the installer then stops before touching the disks
  (`class/15-uefi-only.sh`).
- **Serial console:** amd64 sets `console=ttyS0` for IPMI SOL and cloud consoles. arm64
  sets nothing, and the kernel uses the console the firmware announces (ACPI SPCR), which
  is `ttyAMA0` on QEMU and many Arm servers and `ttyS0` on others.
- **Networking** (cloud and metal) is systemd-networkd with systemd-resolved, configured
  by cloud-init on first boot. Without other network config, cloud-init uses DHCP (IPv4
  and IPv6) on the first NIC with a link. LLMNR and multicast DNS are off
  (`files/etc/systemd/resolved.conf.d/50-hardening.conf`). For static IPs on metal, use cloud-init
  `network:` config: put a `network-config` file in the NoCloud seed.
- **Changing the username:** it lives in two places, `default_user` in
  `files/etc/cloud/cloud.cfg.d/90-fai-defaults.cfg/SERVER` and `AllowUsers` in
  `files/etc/ssh/sshd_config.d/10-cis.conf/HARDEN` (plus `SSH_USER` in the Makefile for `make ssh`).
- **GitHub keys are imported once,** at first boot. Keys you add or remove on GitHub
  later aren't synced. Run `ssh-import-id gh:garbee` (adds) or edit `~/.ssh/authorized_keys`.
  If GitHub may be unreachable at first boot, also list a key under
  `ssh_authorized_keys:` in `user-data`. Otherwise a failed import leaves no way in.
- Upstream docs: `man fai-diskimage`, `man fai-cd`, `man setup-storage`,
  https://fai-project.org/fai-guide/
