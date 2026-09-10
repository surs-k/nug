# Rebuild

___

Automated Arch install, v4.0. Runs itself once you answer the questions at the start.


# Start

___


## Iso

___

**From the live USB:**

```
loadkeys colemak
git clone <your-repo> Rebuild
cd Rebuild
chmod +x iso/iso.sh
./iso/iso.sh
```

	• Answers all at start
	• Then hands off
	• Reboot at the end

The repo copies itself to your home folder, so you do not clone it twice.


## Rest

___

**After the first boot, log in and run:**

```
cd ~/Rebuild && ./run.sh
```

	• Asks once
	• Runs every stage
	• Stops only for reboots

When it stops, reboot and run the same command again. It picks up where it left off.


# Stages

___


	• **iso:** partitions, encrypts, installs base
	• **10-base:** locale, boot, swap, yay
	• **20-desktop:** graphics driver and HyDE
	• **30-security:** Mullvad and firewall
	• **40-virt:** KVM and the VM network
	• **50-bkp-net:** Tailscale, SSH, snapshots
	• **60-uprefs:** apps, keybinds, monitors
	• **70-docker:** self hosted services
	• **80-remote:** Sunshine for the laptop


# Reading

___

Each stage prints one line per step. Full output goes to a log, not your screen.

**Logs live here:**

```
~/.rebuild/logs/
```

**To watch everything instead:**

```
REBUILD_VERBOSE=1 ./run.sh
```

Package installs stay visible either way, because the download bar is the progress.


# Rerun

___

Every stage is safe to run again. Nothing is destructive after the ISO stage.

**To redo one stage:**

```
rm ~/.install-state/30-security
./run.sh
```

**To change an answer:**

```
nano ~/.install-config
```


# Guides

___


	• **Backups:** snapshots and rollback
	• **Network:** when internet breaks
	• **Selfhost:** starting your services


# Risk

___


• **The ISO stage wipes two disks:** it names both and waits for YES, but there is no undo after that point

• **TPM unlock is convenience, not security:** with Secure Boot off, PCR 7 proves very little, and your passphrase always still works

• **Snapshots are not backups:** they sit on the same disks, so a dead drive takes both, and a second disk is still on your list

• **Tailscale runs outside the VPN tunnel:** that is deliberate and required, but it means tailnet traffic is not Mullvad traffic

• **The AUR packages can break:** Sunshine, 1Password, VSCodium and LibreWolf are community built, so a failed build warns and continues instead of stopping the run
