Default: Hardened server

Name: Hardened server
Description: Debian trixie server, CIS Level 1 Server, LVM, UEFI
Short: Physical server. WIPES THE FIRST DISK. Configured by cloud-init on first boot.
Long: Installs a minimal hardened Debian trixie server onto the first disk
using a CIS-style LVM layout (separate /var, /var/log, /var/log/audit,
/home, /tmp). Packages are downloaded during the install (network needed).
Root is locked; on first boot cloud-init creates 'jonathan' with the SSH keys
from GitHub (gh:garbee), as set in cloud-init/user-data.
Classes: INSTALL FAIBASE DEBIAN SERVER HARDEN METAL

Name: Server (no hardening)
Description: Same as above without the HARDEN class
Short: For comparing/debugging when a CIS control breaks something. NOT compliant.
Long: Identical to the hardened profile without the HARDEN class (no CIS
controls: firewall, sshd/PAM/sudo policy, AIDE, sysctl, ...). Useful to bisect
problems caused by HARDEN; never use it for real machines.
Classes: INSTALL FAIBASE DEBIAN SERVER METAL
