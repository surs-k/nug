# Problems
___


Every known problem, open until v2 fixes it. **Quiet** means nothing on screen tells you about it.

| # | Problem | Area | Quiet | Status |
| --- | --- | --- | --- | --- |
| 1 | Disk unlocks by TPM with no PIN, Secure Boot off, boot line editable | Security | yes | open |
| 2 | HyDE, AUR packages and Docker `:latest` images are not pinned, an update can change anything | Security | yes | open |
| 3 | Stash with passwords, SSH host keys and the Mullvad number stays on disk after a failed run | Privacy | yes | open |
| 4 | `ufw-docker` is a root script downloaded from master | Security | yes | open |
| 5 | Docker bypasses the firewall, only loopback binds hold it back | Security | yes | open |
| 6 | Sunshine user is in the `input` group, which reads every keyboard | Security | yes | open |
| 7 | btrbk can write to an unmounted `/mnt/backup`, the OS disk filled once | Recovery | yes | open |
| 8 | No LUKS header backup, no restore ever tested | Recovery | yes | open |
| 9 | Data disk mounts lack `nofail`, a missing disk drops boot to emergency mode | Recovery | no | open |
| 10 | "Keep the data disk" defaults to No | Recovery | no | open |
| 11 | DNS has four owners, lookups have stalled | Privacy | yes | open |
| 12 | Kernel update without reboot breaks Docker and modules | Management | no | open |
| 13 | Each reinstall adds a duplicate UEFI entry and a new Tailscale node | Management | yes | open |
| 14 | Keys `SUPER+C` and `SUPER+R` exist even when their app is skipped | Visuals | no | open |
| 15 | Scripts point to `Guides/*.md` that do not exist | Educating | no | open |

#Ai - from the v1 audit. Security and privacy review per phase adds rows here
