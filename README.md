# Battery Optimizer for Android

ADB-based battery optimizer and cleanup tool for Android. Runs from Linux, Windows or the browser over USB debugging. No root, nothing installed on the phone.

**https://azp3001.github.io/battery-optimizer/web/**

## Features

- **MAX BATTERY**: power saving, dark mode, deep sleep, battery settings, app restrictions and background data blocking in one step. `RESTORE` undoes it.
- **Extra savers** (optional, never applied by MAX BATTERY): 5G off, diagnostics apps off, lower screen resolution, 85% charge limit on Samsung.
- **Bloatware**: remove preinstalled apps (Netflix, Meta services, ...) for your user; they can be brought back.
- **Top battery users**: apps that used the most battery since the last full charge, ready to restrict.
- **Battery status**: level, temperature, health and estimated capacity.
- **Keep list**: apps that keep running in the background (messengers, banking). Everything else is restricted once (no constant killing, so apps don't restart over and over).
- **App control**: per app or for a selection: background running, wake locks, start at boot, background mobile data, notifications, standby bucket, enable/disable.
- **Deep sleep**: Doze 30 s after screen off (on phones that allow it over USB; otherwise quick doze via power saving).
- **Permissions**: by permission or per app, including special access (usage access, install unknown apps, all files access, ...).
- **Storage**: apps and files by size; uninstall, clear data, clear caches, secure file delete.
- **Backup / restore**: one `.zip` per app with the app (all split APKs), its `Android/data` and `Android/obb` files, and optionally Android's own backup. Same format in the web app and the script. Without root, private app data and logins mostly stay on the phone; apps that opt out of Android's backup need a new login after restore.
- **Install**: drag in `.apk` files or split bundles (`.apks`, `.xapk`, `.apkm`, with OBB data); shows name, icon and version first, installs over USB.
- **F-Droid store** (web app Install tab and script): search open-source apps, download the version that fits the phone, verify its SHA-256, install over USB. The web app reads a daily copy of F-Droid's list (`web/fdroid.json`, refreshed by a workflow) and picks the downloaded APK up from the Downloads folder.
- **Cleanup**: contacts, calendar, call log, SMS, saved Wi-Fi networks, settings reset, keyboard learned words, screen lock removal, free RAM, TRIM.
- Storage and Cleanup only open after the phone's screen lock is typed, and every delete, reset, uninstall, clear-data and restore asks for it again. The phone checks it; the field shows dots.

## Setup: USB debugging

Settings > About phone > tap **Build number** 7 times. Then Settings > Developer options > **USB debugging** on. Plug in and allow the computer on the phone.

## Web app

Open the link above, press **Connect**, pick the phone. App names, icons and the keep list are stored in the browser. Close other ADB programs first (`adb kill-server`).

## Windows

Download `battery-optimizer-windows.bat` and `battery-optimizer-linux.sh` from [Releases](https://github.com/AZP3001/battery-optimizer/releases) into one folder and double-click the `.bat`. On first start it downloads portable bash, Python, fzf and adb (about 130 MB) into `%LOCALAPPDATA%\battery-optimizer`; nothing is installed system-wide. Windows 10 1803 or newer. Some phones need their USB driver (Samsung USB Driver, Google USB Driver).

## Linux

Requires `adb`, `fzf` and Python 3.12+.

```bash
sudo apt install adb fzf python3
```

Fedora: `sudo dnf install android-tools fzf python3` · Arch: `sudo pacman -S android-tools fzf python`

```bash
chmod +x battery-optimizer-linux.sh
```

```bash
./battery-optimizer-linux.sh
```

## Script commands

| Command | |
|---|---|
| (none) | Menu of all tools |
| `battery` | MAX BATTERY, keep list, settings, deep sleep, mobile data, radios, status, RESTORE |
| `optimize` / `unoptimize` | Restrict or allow apps in the background |
| `autostart` | Apps that start at boot; block or allow |
| `permissions` | Permissions by type |
| `cleanup` | Files and apps (biggest first), contacts, calendar, call log, SMS, app data, settings, keyboard words, screen lock, disable apps, notifications, free RAM, TRIM, backup and restore |
| `store` | Search and install apps from F-Droid |
| `install FILE.apk` | Install an APK (split bundles too) |
| `help` | Description of every tool |
| `selfcheck` | Parser self-test, no phone needed |

Keys: arrows to move, **Enter** to choose, **Tab** to select several, **Esc** to go back.

## Safety

- Critical system packages are hidden or protected; "not recommended" ones are marked.
- Deletes are permanent: files are overwritten before removal and skip the trash.
- `RESTORE` undoes everything the Battery tool changed.
- The app tables know Samsung, Google and Nothing best; settings a phone doesn't have are skipped.

## Stored data

| Script | Web app | |
|---|---|---|
| `~/.config/phone-keep.json` | browser storage | Keep list |
| `~/.config/phone-battery-backup.json` | browser storage (per phone) | Old values for RESTORE |
| `~/.config/phone-cleanup-exceptions.json` | keep list | Apps never closed by hard "free RAM" |
| `~/.cache/phone-cleanup-*.json` | browser storage | App name / icon cache |
| `~/.cache/phone-fdroid-index-v1.jar` | | F-Droid app list (refreshed daily) |
| `~/phone-backups/*.zip` | folder you choose | App backups |

On Windows `~` is `C:\Users\<you>`. Clearing the site's data in the browser loses the web app's keep list and RESTORE backup.

## Development

- `battery-optimizer-linux.sh`: the whole tool (bash front end + Python). The `.bat` downloads dependencies and runs it.
- `web/`: the web app. `webadb.js` bundles [ya-webadb](https://github.com/yume-chan/ya-webadb) (MIT); `apk.js` reads app names and icons from APKs. The page reads its app table from the script.
- GitHub Pages republishes on every push to `main`.
- Release: Actions > Release > Run workflow, enter the version (e.g. `v1.2`).
