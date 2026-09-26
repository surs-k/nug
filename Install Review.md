# Using
___


Only the things I want to change, in the order you'll see them during an install.

	• Read along while installing
	• Answer under each #Ai line
	• Tab then # for answers


**Each item:**

	• Witness: what you'll see
	• Change: what I'd do
	• Why change
	• Why this
	• Questions for you


**Evidence tags:**

	• well-supported: checked in code
	• practice only: your call
	• contested: needs one test


# Before
___


## Folders
___


**Done:**
you chose lowercase, so the folders stay scripts, configs and stacks and the code now uses lowercase. 05-iso is now iso.sh


**Witness:**
at the end of 05-iso, `[ok]   repo copied`. Before the rename it said `[FAIL] could not confirm: repo copied`


**Change:**
rename scripts, configs and stacks to Scripts, Configs and Stacks


**Why change:**

The code looks for the folders with capitals. Linux treats `scripts` and `Scripts` as two different folders, so 05-iso can't find what it copied. Later, the `rebuild` command can't find run.sh, 60-uprefs stops at the wluma config and 70-docker stops at the stacks.


**Why this:**

Renaming is three commands. Changing the code instead means editing five lines of code and many comments, and the code already agrees with itself on capitals.


**Evidence:**
well-supported


#Ai - your local copy on the PC needs the same lowercase names and iso.sh rename


# 05-iso
___


## TPM
___


**Witness:**
in the Bootloader section, `TPM enrolled` or, in a VM without a virtual TPM, `no TPM device, skipping`. Later, 10-base prints `Secure Boot is off, TPM unlock is convenience only`


**Change:**
enrol the TPM with a short PIN, by adding `--tpm2-with-pin=yes` at 05-iso.sh:551


**Why change:**

Right now the TPM unlocks the disk by itself at boot, and Secure Boot is off. So anyone holding the PC can change the boot line to open a root shell, and the TPM still unlocks the disk for them. The encryption then does nothing against theft.


**Why this:**

A PIN is one flag. You keep the TPM's convenience, a short PIN instead of the long passphrase, and the TPM locks out after too many wrong guesses. The other options are bigger: set up Secure Boot with your own keys, which can break booting with Limine, or drop the TPM and type the full passphrase every boot.


**Evidence:**
well-supported


**VM test:**

To see the TPM path in the VM, add a virtual TPM before installing.

	• virt-manager, VM details
	• Add Hardware
	• TPM, Emulated, 2.0


#Ai - does your real PC have a TPM, and is Secure Boot on or off in its firmware?


#Ai - would you type a short PIN, 4 to 6 digits, at every boot?


#Ai - is someone taking the PC itself a worry for you, or mostly online threats?


# First boot
___


## Editor
___


**Witness:**
the boot menu shows for 1 second. Press an arrow key to stop the count, then press E on Linux, and an editor opens on the kernel line


**Change:**
turn the editor off, by having limine-header-fix write `editor_enabled: no` under the timeout line (limine-header-fix.sh:561), and adding `editor_enabled` to the keys it drops at limine-header-fix.sh:253


**Why change:**

The editor is the easy way to do the attack in TPM above. Anyone at the menu can add one word to the kernel line and get a root shell.


**Why this:**

The menu tool rewrites limine.conf every time, so the setting has to live in the tool or it gets wiped. The drop list stops the line doubling on every rerun. It isn't full protection, since the menu file sits unencrypted on the boot partition, which is why the PIN matters more.


**Evidence:**
well-supported


#Ai - have you ever edited the boot line by hand, for example to fix a black screen?


#Ai - with the editor off, the way back from a bad boot is the ISO or `limine-header-fix --flat`, is that okay?


# 20-desktop
___


## Downloads
___


**Witness:**
`clone HyDE`, then `HyDE installer starts now`


**Also seen:**

	• 10-base: clone yay-bin
	• 50-bkp-net: AUR builds
	• 60-uprefs: AUR builds
	• 70-docker: fetch ufw-docker
	• 80-remote: Sunshine build


**Change:**
pin HyDE and ufw-docker to a commit hash, and check ufw-docker's sha256 before running it


**Why change:**

These run whatever the newest version is on install day. ufw-docker runs as root straight from its master branch, and HyDE's installer changes your whole desktop. Whoever controls those repos that day controls your PC.


**Why this:**

A pin is one line per download, and you update on purpose by changing it. It also means the HyDE you test in this VM is the exact HyDE your real PC gets.


**Evidence:**
well-supported


#Ai - do you want the newest HyDE on every install, or the exact version you tested in the VM?


#Ai - AUR builds currently skip the screens that show what changed in each package, keep skipping them for speed, or see them?


## Keyboard
___


**Witness:**
`colemak written to hyprland.lua`, then `if the layout ever breaks again, type: kbfix`. In 60-uprefs, `keyboard is colemak right now`


**Change:**
make kbfix check first and only write when the block is missing or wrong, then have 20-desktop and 60-uprefs just call `kbfix`


**Why change:**

The same keyboard block is written in three places: 20-desktop.sh:187, inside kbfix at 20-desktop.sh:210, and 60-uprefs.sh:308. Changing the layout means three edits, and missing one makes them disagree.


**Why this:**

This is your check and write only when needed. kbfix is already the command you type when the layout breaks, so the install and you use the same fix.


**Evidence:**
well-supported


#Ai - has the layout broken since v7, or is the re-check in 60-uprefs only a safety net?


#Ai - is it always colemak, or might you change KEYMAP one day?


# 30-security
___


## Mullvad
___


**Done:**
option B. The desktop installs and reboots first, as before. The run after the reboot asks for the number with the sudo password, keeps it in memory only, and 30-security uses it


**Witness:**
after the reboot, `rebuild` asks for your sudo password, then `Mullvad needs your account number. It is kept in memory only.` Then it runs hands off


#Ai - option A, security before the desktop, broke HyDE's installer in the VM, so it was dropped


# 50-bkp-net
___


## Backup
___


**Witness:**
`first home snapshot`


**Change:**
send btrbk's daily /home snapshots to a second disk as well


**Why change:**

The snapshots sit on the same disk as /home. The code itself says "this is not a backup, it is an undo button". If that disk dies, every snapshot dies with it.


**Why this:**

btrbk is already set up and already has a commented-out second disk block. It needs a disk mounted at /mnt/backup and one target line under each subvolume, no new tool.


**Evidence:**
well-supported


#Ai - do you have a second drive for backups, inside the PC or USB?


#Ai - would it stay plugged in, or be plugged in now and then?


#Ai - should the install set it up, or would you do it by hand later?


## Guides
___


**Witness:**
at the end of 50-bkp-net, `Read Guides/Backups.md before you need it, not after.` It shows again in 70-docker, 90-health and at the very end of the run


**Change:**
remove the guide pointers, or swap each for the one command it would have told you


**Why change:**

The Guides files aren't in the repo, and you said you don't use them. A pointer to nothing is a line to read for no gain.


**Why this:**

One line in 90-health (90-health.sh:258) is a real failure message with a pointer on the end. There I'd only cut the pointer, not the message.


**Evidence:**
well-supported


#Ai - delete them, or swap for one command, like `snapper -c root list` for backups and `stack list` for services?


# 70-docker
___


## Latest
___


**Witness:**
`download searxng`, `download invidious` and so on, one per service you picked


**Change:**
pin each image to a version, except invidious and its companion


**Why change:**

Five images use `:latest` and comfyui uses a `-latest` tag. An update can break a service with no warning, and whatever the publisher pushes next runs on your PC. It also means the VM and your real PC can end up on different versions.


**Why this:**

A version tag you bump on purpose is readable and easy to change. Invidious stays on latest because YouTube breaks old versions fast. Postgres and valkey are already pinned, so this follows the pattern you started.


**Evidence:**
practice only


#Ai - how often would you update services, monthly, only when something breaks, or never?


#Ai - want a `stack update <name>` command that shows the new version and asks before switching?


# 80-remote
___


## Input
___


**Witness:**
`add user to input`


**Change:**
drop that line, then test `remote on` from the laptop


**Why change:**

The input group can read every keystroke from every keyboard. So can any program you run, including a bad one.


**Why this:**

The rule at 80-remote.sh:91 already gives your session the virtual keyboard and mouse Sunshine makes. One test shows whether the group is needed at all.


**Evidence:**
contested


#Ai - do you use a game controller through Moonlight? Controllers may need more than the keyboard and mouse do


#Ai - will you test Sunshine in the VM, or only on the real PC?


# 90-health
___


## Tailnet
___


**Done, lockdown part:**

the install never turns lockdown on now, you turn it on in the Mullvad app when your settings are done


**Witness:**
a stage banner says 35-TAILNET, stage 10 of 10


**Change:**
rename 35-tailnet to 95-tailnet


**Why change:**

The name says 35 but it runs last, which is confusing in `rebuild --list`. And your services are set up before a tailnet address exists, so 70-docker and 80-remote have to run again.


**Why this:**

Running it last is a good call, since it's fragile and nothing needs it. This keeps it last and makes the name match.


**Evidence:**
practice only


#Ai - will you turn Tailscale on in the VM?


#Ai - after Tailscale connects, should the run open your services to the tailnet by itself, instead of you rerunning 70-docker and 80-remote?


# Code
___


Not on screen, only when reading the scripts.


## Library
___


**Change:**
move six helpers only 05-iso uses out of 00-lib.sh and into 05-iso: partsuffix, partname, pick_disk, require_disk, secret_twice, confirmed


**Why change:**

00-lib.sh is 1140 lines, and every stage loads all of it. Only 644 lines are code. Every stage also loads disk and password helpers it never uses.


**Why this:**

Splitting the whole library into several files means more places to look, not fewer. Moving only what one stage uses keeps the library to what every stage needs.


**Evidence:**
practice only


#Ai - do you read or edit the scripts yourself, or only through an AI? If only through an AI, I'd skip this one


## History
___


**Change:**
move notes about older versions, like "before v7.0" and "earlier versions", into commit messages, keeping only the current reason in the code


**Why change:**

When you read the code, you have to sort what's true now from what used to be true. That's extra reading.


**Why this:**

A commit message is attached to the change that caused it, so the history stays findable with `git log` without sitting in every file.


**Evidence:**
practice only


#Ai - do those history notes ever help you, for example to stop an old mistake coming back?
