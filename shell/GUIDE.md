# Dream shell guide

Every part of the desktop, what it is for, and the one place that changes it.

Start with the Settings window. Go to a file only when the window does not have what you want.

## The three depths

Everything on the bar works the same way.

| You do | You get |
|---|---|
| Look | The few things you need most |
| Rest the pointer on a piece | A little more |
| Click it | Everything, with the controls |

## Quick answers

| I want to | Do this |
|---|---|
| Open Settings | `SUPER + I`, or right-click an empty part of the bar, or run `dream settings` |
| Open the launcher | `SUPER + A`, then just type |
| Change the look | Settings, Look. Or `SUPER + ALT + Up` for the next one |
| Go back to the HyDE bar | `dream off`. Windows stay where they are |
| Return to Dream | `dream on` |
| Pick a desktop at login | Choose Dream or Hyprland in the session list on the login screen |
| See what went wrong | `dream log` |
| Undo a setting I broke | Delete `~/.config/dream/settings.json` and run `dream reload`. Defaults come back |

## Where things live

| Folder or file | Holds | Safe to edit |
|---|---|---|
| `~/.config/dream/settings.json` | Every choice you have made | Yes. Changes apply the moment you save |
| `~/.config/dream/looks.json` | The looks: colours, roundness, font | Yes. Copy a block to make a new look |
| `~/.config/dream/hypr/dream.lua` | Keys and blur for Dream on Hyprland | Yes. Run `hyprctl reload` after |
| `~/.config/quickshell/dream/` | The shell itself, one file per part | Yes, but the install script writes over it. Copy your change into the repo's `shell/` folder to keep it |
| `~/.local/state/dream/` | How often you opened each program | Delete it to reset the launcher order |

## The parts

Each part is one file in `~/.config/quickshell/dream/`. The top of each file says what it does.

| Part | File | What it is for |
|---|---|---|
| Bar | `Bar.qml` | Holds the pieces. Reorder or remove a piece by moving or deleting its line near the bottom |
| Time | `ClockChip.qml` | Time only. Rest on it for the date, click for clock choices |
| Performance | `PerfChip.qml`, `Perf.qml` | Readings you tick show on the bar with a small icon each |
| Workspaces | `Workspaces.qml` | Only open ones. Filled is this screen, coloured is the other screen |
| Tray | `TrayChip.qml` | Running programs. Grid button folds them; right-click it for the task manager |
| Sound | `AudioChip.qml` | Scroll to change volume, middle-click to mute. Media controls are under the click |
| Connections | `NetChip.qml`, `Net.qml` | Wired, Wi-Fi and Bluetooth together |
| VPN | `VpnChip.qml`, `Vpn.qml` | Green shield is connected, red is not |
| Updates | `UpdatesChip.qml`, `Updates.qml` | Counts waiting updates. Nothing installs until you press Update now |
| Notifications | `BellChip.qml`, `NotifPopups.qml`, `Notifs.qml` | Bell shows only when something waits |
| Launcher | `Launcher.qml`, `Usage.qml` | Type to search. Programs you open here most rise to the top |
| Settings window | `SettingsWindow.qml` | The window you opened this guide from |
| Icons | `Icon.qml` | Every icon is one line. Add your own there |

## settings.json, line by line

| Setting | Means | Default |
|---|---|---|
| `look` | Name of a look from looks.json | `Glass night` |
| `bar.height` | Bar thickness in pixels | 24 |
| `bar.gap` | Space above the bar | 4 |
| `bar.textSize` | Size of text on the bar | 12 |
| `clock.hour24` | 24-hour time | false |
| `clock.seconds` | Show seconds | false |
| `clock.dateOnBar` | Date beside the time | false |
| `performance.onBar` | Readings on the bar: `cpu` `gpu` `ram` `cputemp` `gputemp` `gpupower` | cpu, gpu, gputemp |
| `performance.everySeconds` | How often readings refresh. Higher is lighter | 2 |
| `tray.folded` | Tray icons folded away | false |
| `tray.hidden` | Tray programs you chose to hide | none |
| `launcher.rows` | Programs per page | 8 |
| `launcher.picture` | Picture beside the list | your current wallpaper |
| `notifications.muteUnimportant` | Only important ones pop up | false |
| `notifications.importantOnlyInFullscreen` | In a fullscreen game, only important ones pop up | true |
| `notifications.seconds` | How long a pop-up stays. Important ones stay three times as long | 6 |
| `notifications.programs` | Per program: `important`, `normal` or `silent` | Claude is silent |
| `apps.*` | Which programs the buttons open | kitty, pavucontrol and so on |

## Making a look

Open `looks.json`. Copy one whole block, from its name to its closing brace. Change the name and the values.

| Value | Changes |
|---|---|
| `text`, `muted` | Main and quieter text |
| `accent`, `onAccent` | Highlight colour, and the text drawn on top of it |
| `good`, `warn` | Fine and not-fine colours |
| `chip`, `chipOpacity` | Background of bar pieces. 1 is solid, 0 is invisible |
| `panel`, `panelOpacity` | Background of pop-ups, launcher and notifications |
| `border`, `borderOpacity`, `borderWidth` | The outline |
| `radius`, `chipRadius` | Corner roundness of panels and bar pieces |
| `font` | Any font installed on the PC |
| `wallpaper` | Optional. Full path to a picture set when the look is chosen |

## If something looks wrong

| Sign | Try |
|---|---|
| Bar is gone | `dream reload` |
| Still gone | `dream log`, then `dream off` to use the HyDE bar meanwhile |
| A setting did nothing | Check for a missing comma or quote in the file you edited. `dream log` names the line |
| Two bars | `dream on` again. It stops the HyDE bar |
