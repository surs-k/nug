# Install
___


Four steps, in order. Your PC keeps running v1 until step 3.

| # | Where | What |
| --- | --- | --- |
| 1 | VM | Install v2 in a VM, prove it works |
| 2 | Your PC, v1 | `prep`, it saves what must survive |
| 3 | Your PC, USB | The real install |
| 4 | Your PC, v2 | `rebuild`, then Your turn |


# 1  VM
___


**The VM:**
	- UEFI firmware, 4 CPUs, 8 GB memory
	- Two disks: 40 GB system, 40 GB data
	- Video: Virtio with 3D acceleration on, so Hyprland can start
	- The Arch ISO

**From the ISO:**

```
loadkeys colemak
pacman -Sy git
git clone -b v2 https://github.com/surs-k/nug
bash nug/scripts/iso.sh
```

**Done when:**
it ends with Your turn. Restart, log in, run `rebuild`, restart again, and the login screen appears.

#Ai - `bash nug/scripts/iso.sh --dry-run` shows every step first and changes nothing


# 2  Prep
___


On your PC, still on v1:

```
git clone -b v2 https://github.com/surs-k/nug /tmp/nug
bash /tmp/nug/scripts/prep.sh
```

**Done when:**
it says `ready for the v2 install`. Then run one last backup: `sudo btrbk run`


# 3  Install
___


Same as the VM. The installer finds your disks, keeps the data disk, and shows the plan before it touches anything.

**Done when:**
it ends with Your turn, and every check is ticked.


# 4  Setup
___


Log in on the text screen, then:

```
rebuild
```

It asks two questions and your Mullvad number, then runs on its own. Your turn at the end lists what only you can do.


# Undo
___


| If | Then |
| --- | --- |
| An update breaks the desktop | Btrfs Assistant, or `sudo snapper list` and ask Claude |
| The PC will not start | Arch USB, then `bash nug/scripts/rescue.sh` |
| A module stopped | Fix what it says, run `rebuild` again, it continues |
