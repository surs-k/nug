# Decisions
___


One entry per choice. A choice is changed only by a new entry, so the old reasoning stays.

| # | Decision | Values | Why | Source | Change |
| --- | --- | --- | --- | --- | --- |
| 1 | v2 built beside v1 in the same repo, v1 kept as branch `v1` | Recovery, Management | old install keeps working, every version can be compared | judgment | [compare](https://github.com/surs-k/nug/compare/v1...v2) |
| 2 | The changelog is a window app, `changes`, reading the commit history, no CHANGELOG.md | Visuals, Concise, Educating | plain words first, exact lines on a click, notes copied to Claude, nothing to keep in sync by hand | judgment | `scripts/changes.py` |
| 3 | Changes manages any number of projects, any git repo, and is a project in itself | Management, Educating, Visuals | one calm place for every project, the app is held to the same standard it shows | judgment | `scripts/changes.py` |
| 4 | Boot: systemd-boot with one signed file per kernel (a unified kernel image), Limine and its 639-line repair tool dropped | Security, Concise, Recovery | the kernel line cannot be edited at start, Secure Boot signs exactly what boots, nothing to repair | Arch Wiki: Unified kernel image, systemd-boot | `scripts/iso.sh` |
| 5 | No booting into snapshots from the menu, `rescue.sh` from the USB undoes a bad update instead | Concise, Recovery | the menu sync was v1's most patched part, an undo from the USB covers the same bad day in a few minutes | judgment, your call: say if you want menu snapshots back | `scripts/rescue.sh` |
| 6 | Secure Boot with your own keys, Microsoft's enrolled too | Security | your keys alone can leave the screen black, the graphics card's own firmware is signed by Microsoft | Arch Wiki: Secure Boot, option ROMs | `scripts/modules/95-secureboot.sh` |
| 7 | Disk unlocks with the passphrase, TPM with a PIN offered only after Secure Boot is on | Security | a TPM without Secure Boot and a PIN starts a stolen PC to the login screen | judgment | `scripts/modules/95-secureboot.sh` |
| 8 | Encryption cost pinned to 256 MiB of memory | Recovery | a benchmarked cost once made the second disk look like a wrong passphrase | v1 history | `settings.conf` |
| 9 | fstab written by hand, every disk but the system disk optional | Recovery | a missing disk never stops the PC at an emergency screen, a rollback that swaps @ just works | judgment | `scripts/iso.sh` |
| 10 | Settings that must outlive a reinstall live in @persist on the data disk: backup key, SSH, Tailscale, Mullvad | Recovery, Privacy, Concise | replaces the stash, nothing secret sits in your home | judgment | `scripts/prep.sh` |
| 11 | Plain Hyprland with waybar, fuzzel, mako, hyprlock, greetd, HyDE dropped | Concise, Visuals, Security | one program per job, one theme file, nothing unpinned rewriting your config | judgment, your call: HyDE could come back as a module | `scripts/modules/30-desktop.sh` |
| 12 | One theme file, config/theme.env, every colour and size comes from it | Visuals | change one line and the whole desktop follows | judgment | `config/theme.env` |
| 13 | NVIDIA open modules, built by dkms for both kernels, loaded early | Efficiency | the right driver for this card's generation, the backup kernel works too | Arch Wiki: NVIDIA | `scripts/iso.sh` |
| 14 | zram swap in memory, zswap off | Efficiency | fast swap with nothing on disk, two compressors would work twice | Arch Wiki: zram | `scripts/iso.sh` |
| 15 | DNS has one owner, systemd-resolved, Mullvad and NetworkManager feed it, Tailscale keeps out | Privacy | four owners in v1, lookups stalled | v1 history | `scripts/modules/20-network.sh` |
| 16 | Mullvad stays beside Tailscale, Tailscale runs outside the tunnel | Privacy, Management | kept from v1, it works, your call if you want one layer only | v1, your call | `scripts/modules/50-remote.sh` |
| 17 | Backups: daily to the internal drive, monthly to the external, headers saved, a restore test command | Recovery | three bad days, three copies, and proof they read back | judgment | `scripts/bin/backup` |
| 18 | Backups refuse to run without their drive mounted | Recovery | v1 once wrote 220 GB onto the system disk | v1 history | `scripts/modules/40-recovery.sh` |
| 19 | Root login locked, sudo is the way in, the USB when nothing else works | Security | no second password to guess or forget | judgment | `scripts/iso.sh` |
| 20 | Sunshine gets input through uaccess, not the input group | Security | the group lets any program read every key you type | judgment, to prove on the PC | `scripts/modules/50-remote.sh` |
| 21 | Apps are one list, config/apps.list, a key only while the app is installed | Concise, Visuals | one place to add or drop an app | judgment | `config/apps.list` |
| 22 | ProtonPlus for newer Proton builds | Concise | one small app, also covers Lutris and Heroic if added | judgment | `scripts/modules/70-gaming.sh` |
| 23 | Hosting is optional and starts small: Ollama on this PC only, Podman ready, services later | Privacy, Concise | nothing listens beyond this PC, services return one at a time | judgment | `scripts/modules/80-hosting.sh` |
| 24 | @games keeps its name | Recovery | renaming a subvolume on the kept disk is a risk for no gain yet, your call | your call | `scripts/iso.sh` |
