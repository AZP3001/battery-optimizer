# Battery Optimizer for Android (Linux, Windows and browser)

**Make your Android phone's battery last much longer, controlled from your computer over a USB cable.**

No root needed. No app to install on the phone. One script, one menu.

> 🌐 **Try it in the browser:** https://azp3001.github.io/battery-optimizer/web/
> ⚠️ The website is **experimental** and **not recommended over the scripts yet**. It has the Battery, Optimize, Autostart and Permissions tools, real app names and icons, a Storage tab (apps and files by size: uninstall, clear data, delete files) and some Cleanup tools (free RAM, flush free space, install an APK). Deleting contacts, messages and settings is only in the scripts. It has not been tested as much. For now, use the Linux script or the Windows file below.

## What it does, in plain words

Most battery drain happens while the phone is in your pocket: apps wake up, run in the background, use mobile data and keep the phone from sleeping. This tool stops that.

1. **You pick the apps that must keep working** (for example WhatsApp, Signal, banking, school). This is the *keep list*.
2. **Every other app gets put to sleep**: it can no longer run in the background, wake up the phone, or use mobile data in the background. It still works normally when you open it.
3. **Battery-hungry settings get switched off**: power saving and dark mode on, Always On Display off, Wi-Fi/Bluetooth scanning off, wake gestures off, 30 s screen timeout, and more.
4. **The phone goes into deep sleep** about 30 seconds after the screen turns off, instead of after many minutes.
5. **Everything can be undone** with one button (`RESTORE`). The tool saves every old value before changing it.

Apps are restricted **once**, not killed over and over. Killing apps on a timer makes them restart, and restarting costs more battery than letting them sleep.

## First: turn on USB debugging on the phone

1. Settings > About phone > tap **Build number** 7 times.
2. Settings > Developer options > turn on **USB debugging**.
3. Plug the phone into the computer and tap **Allow** on the phone.

## Windows

1. From the [Releases](https://github.com/AZP3001/battery-optimizer/releases) page, download **both** `battery-optimizer-windows.bat` and `battery-optimizer-linux.sh` into the same folder.
2. **Double-click** `battery-optimizer-windows.bat`.

That's it. The first start downloads the tools it needs by itself (about 130 MB, once) into `%LOCALAPPDATA%\battery-optimizer`. You don't have to install anything. Then the same menu as on Linux opens. Nothing is done to the phone until you choose it in the menu.

If the `.bat` is on its own, it fetches the latest script from GitHub.

Needs Windows 10 (version 1803) or newer. If the phone does not show up, Windows may need the phone's USB driver (Samsung: *Samsung USB Driver*, Pixel: *Google USB Driver*).

## Linux

You need `adb` (Android platform tools), `fzf` (menus) and `python3` 3.12 or newer.

```bash
sudo apt install adb fzf python3
```

Fedora: `sudo dnf install android-tools fzf python3` · Arch: `sudo pacman -S android-tools fzf python`

Download `battery-optimizer-linux.sh` from the [Releases](https://github.com/AZP3001/battery-optimizer/releases) page, then:

```bash
chmod +x battery-optimizer-linux.sh
```

```bash
./battery-optimizer-linux.sh battery
```

## How to use it

Open the **Battery** tool, choose **MAX BATTERY**, pick your keep list, type `GO`. Done. Restart the phone once afterwards.

Use the arrow keys to move, **Enter** to choose, **Tab** to select several, **Esc** to go back.

## All tools

Run the script with no argument for a menu of everything, or name a tool directly (on Windows, double-click opens the menu):

| Command | What it does |
|---|---|
| `battery` | Everything for battery life in one place: MAX BATTERY, keep list, settings, deep sleep, mobile data, radios, status, RESTORE |
| `optimize` | Pick apps one by one and stop them from running in the background |
| `unoptimize` | Allow optimized apps to run in the background again |
| `autostart` | See which apps start themselves when the phone boots, and block them |
| `permissions` | See which apps have Camera, Location, Microphone, etc. and take permissions away |
| `cleanup` | Securely delete files, contacts, SMS, call log, app data; disable apps; manage notifications; free RAM |
| `install FILE.apk` | Install an app from your computer onto the phone |
| `help` | Explain every tool |
| `selfcheck` | Test the script's internals (no phone needed) |

## Is it safe?

- Critical system parts (calls, SMS, settings, keyboard, home screen) are hidden or protected, so you cannot switch them off by accident.
- Apps that are *not recommended* to touch are shown in yellow.
- Anything that deletes data asks you to confirm first, and "delete all" asks you to type a word.
- `RESTORE` in the Battery menu undoes every change the Battery tool made.
- **The `cleanup` tool deletes for real.** Files are overwritten before removal and do not go to a trash bin. Read before you confirm.

The built-in app lists know Samsung, Google and Nothing apps best. Other brands work too; settings a phone does not have are skipped.

## Files it keeps on your computer

| File | What it is |
|---|---|
| `~/.config/phone-keep.json` | Your keep list |
| `~/.config/phone-battery-backup.json` | Old values, used by RESTORE |
| `~/.config/phone-cleanup-exceptions.json` | Apps never closed by "free RAM" |
| `~/.cache/phone-cleanup-*.json` | Cached app names (safe to delete) |

On Windows `~` is your user folder (`C:\Users\<you>`). The website keeps the keep list and the RESTORE backup in the browser instead, so clearing the site's data loses them.

## For developers

- `battery-optimizer-linux.sh`: the whole tool (bash and Python). The Windows `.bat` only downloads the tools and runs this same file.
- `web/`: the website. `web/webadb.js` is a bundle of [ya-webadb](https://github.com/yume-chan/ya-webadb) (MIT) that talks to the phone over WebUSB. The page reads its app table from the script.
- Every push to `main` that touches the website or the scripts republishes GitHub Pages automatically.
- To make a release: Actions > Release > Run workflow, enter the version (for example `v1.1`).
