# Testing the install

How to prove the install does what you want, before it touches the real PC.

## The one command

```bash
bash ~/rebuild/scripts/vm-test.sh run
```

It builds a throwaway virtual machine with two blank disks, installs the whole system into it hands off, runs every stage, and prints the verify report. No root needed. Nothing outside `~/.cache/rebuild-vm` is touched.

It takes one to two hours, mostly downloads. It needs an Arch install ISO; it looks in `~/Downloads` and `~/firelink/vm-storage/iso`, or pass `--iso FILE`.

## Then look inside

```bash
bash ~/rebuild/scripts/vm-test.sh open
```

The installed system opens in a window. Log in with the user and password from `scripts/vm-answers.conf`. Every desktop you chose is in the session list on the login screen.

| Command | Does |
|---|---|
| `vm-test.sh run` | Install from scratch and fetch the report |
| `vm-test.sh run --desktops plasma,gnome` | Same, with those extra desktops |
| `vm-test.sh open` | Start the installed VM in a window |
| `vm-test.sh report` | Show the last report again |
| `vm-test.sh log` | Follow what the VM prints |
| `vm-test.sh shot` | Save a picture of the VM screen |
| `vm-test.sh stop` | Switch the VM off |
| `vm-test.sh clean` | Delete the VM and its disks |

To change what the test installs, edit `scripts/vm-answers.conf`. Those are the same answers a real install asks you for.

## The verify report

```bash
rebuild verify
```

Runs on the VM and on the real PC. It changes nothing. It reads the system and says, in groups, what is true right now:

| Group | Answers |
|---|---|
| Security | Who can get in: disk encryption, how disks unlock, firewall, what listens, remote login, admin rights |
| Privacy | What leaves the PC: VPN, name lookups, services open to the network, everything that runs without you |
| Sandbox | What each app can touch: which apps are fenced off, which are published by their own author, which can read your whole home folder |
| Recovery | Undoing a mistake: system snapshots, home snapshots, copies on a second disk |
| Performance | Startup time and its slowest parts, memory and its largest users, disk, graphics driver, logged errors |
| Desktops | What you can log in to |

Each line carries one of these:

| Mark | Means |
|---|---|
| `ok` | As wanted |
| `look` | Works, but worth your eyes or a decision |
| `bad` | Not as wanted, and it weakens something |
| `gap` | Wanted in `SPEC.md`, not built yet |

Under each line: **why** it matters, and **check**, the command that shows the same thing, so nothing has to be taken on trust.

The report is saved to `~/rebuild-report.txt`. It holds no addresses, serials, or keys.

## Desktops

HyDE on Hyprland is the base and always stays. Others are extra choices on the login screen.

```bash
desktop
```

Lists every desktop, which are added, and what each is best for. Also in the app launcher as **Desktops**.

| Command | Does |
|---|---|
| `desktop add plasma` | Installs it and puts it on the login screen |
| `desktop remove plasma` | Removes it and exactly the packages it brought in |
| `desktop restore plasma` | Puts shared settings back as they were before it was added |

To switch: log out, pick from the list on the login screen, log in.

Settings that desktops share (GTK, Qt, KDE globals) are copied aside before each add. A desktop can still change them while you use it; `desktop restore` is the way back.

## Windows for seeing and changing things

All four are in the app launcher.

| Window | Shows | Change it there |
|---|---|---|
| OpenSnitch | Every connection, by program, as it happens. Asks the first time a program reaches out | Allow or refuse a program; your answers become rules |
| Firewall Configuration (Gufw) | Whether the firewall is on, and every rule for what may come in | Add or remove a rule |
| Flatseal | What each sandboxed app may touch: files, network, devices | Switch any permission off |
| Warehouse | Every sandboxed app and the data it keeps | Remove an app with all its data |

OpenSnitch starts in learning mode: a connection nobody answers for is allowed, so nothing breaks while you watch. Once your rules look right, switch it in OpenSnitch, Preferences, to deny.

## Adding and removing apps

Apps installed as Flatpaks are sandboxed, and removing one removes its data too. The list is `configs/flatpaks.conf`, one app per line:

```bash
rebuild --only 60-uprefs
```

installs whatever the list holds. Apps installed the Arch way (Steam, browsers, the system itself) are not sandboxed, and removing one leaves its settings in your home folder. The verify report counts them.

## What only the VM test changes

Hands-off mode gives the test VM passwordless admin rights and a service that carries the install on after each reboot. Both are refused on real hardware, and the report flags them. A real install asks you everything once, as before.

## What the VM cannot show

- The NVIDIA card, monitors, sound, and game performance.
- The VPN connected: the test has no account, so the VPN lines read as not connected.
- Secure Boot with your real firmware.
