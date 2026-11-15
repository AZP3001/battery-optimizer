#!/bin/bash
# battery-optimizer-linux.sh (Linux only): every Android phone tool in one file (phone connected by USB debugging), plus the Battery tool.
#   ./battery-optimizer-linux.sh           menu
#   ./battery-optimizer-linux.sh battery   straight into the Battery tool
#   ./battery-optimizer-linux.sh help      what every tool does
# Layout: small bash front end, the app list tool (appops), then the cleanup tool (Python) at the bottom.
self=$(realpath "$0")
# the Python part calls back here for the shared app table (as a Windows path when run from the .bat)
export PHONE_SELF=$(cygpath -w "$self" 2>/dev/null || echo "$self")

# Install an APK over USB. Handles normal APKs and split-APK bundles (.apks/.xapk/.apkm).
install_apk() {
    [ -f "$1" ] || { echo "usage: $0 install <file.apk>" >&2; return 1; }
    if unzip -Z1 "$1" 2>/dev/null | grep -qx 'AndroidManifest.xml'; then
        adb install -r "$1"
        return
    fi
    # No manifest at the top level: a split-APK bundle (.apks/.xapk/.apkm) named .apk
    local tmp rc
    tmp=$(mktemp -d) || return 1
    unzip -qoj "$1" '*.apk' -d "$tmp" && adb install-multiple -r "$tmp"/*.apk
    rc=$?
    rm -rf "$tmp"
    return $rc
}

# Print the help sheet (shown by 'help' and the Help menu row).
phonehelp() {
    cat <<'SHEET'
  Phone tools (phone connected by USB debugging)
  Run  ./battery-optimizer-linux.sh  for the menu, or  ./battery-optimizer-linux.sh TOOL  to open one tool directly.
  -------------------------------------------------
  battery      Everything for maximum battery life, in one place.
               Keep list: the apps that must keep working (messages,
               school, banking). Everything else gets restricted.
               MAX BATTERY: does all of the following in one go.
               Apps: every app not on the keep list may not run in the
               background or hold wake locks, and goes in the Restricted
               bucket. Done once, not a constant killer, so apps do not
               restart over and over.
               Mobile data: Data Saver on, so no app uses mobile data in the
               background, except the keep list. Wi-Fi is not affected.
               Mobile data per app: block or allow app by app instead.
               Settings: power saving, dark mode, no AOD, no wake gestures,
               no scanning, mobile data off while on Wi-Fi, app freezer,
               no touch sounds or vibration, 30 s screen timeout.
               Deep sleep: the phone goes into deep sleep about 30 s after
               the screen turns off, instead of after many minutes.
               Radios: Wi-Fi, mobile data, Bluetooth, NFC, location on/off.
               Extra savers (optional, never applied by MAX BATTERY): 5G off,
               diagnostics apps off, lower screen resolution, and on Samsung
               a charge limit of 85% for a longer battery lifespan.
               Battery use: the apps that used the most battery since the
               last full charge, biggest first. Enter restricts them. Also
               shows screen-on time and what keeps the phone awake right
               now, and can start a new measurement.
               Sleep now: screen off and straight into deep sleep.
               Status: what is applied right now, plus battery temperature,
               health and estimated capacity.
               RESTORE: undo everything the Battery tool changed.
  optimize     Pick apps from a list. Each one is blocked from running in the
               background, holding wake locks and starting foreground
               services, force-stopped and put in the Restricted standby
               bucket. Green = fully optimized.
               Order: your apps, safe preinstalled extras, then system parts
               (yellow, not recommended). Critical system parts are hidden.
               Tab marks several, Enter applies to everything marked.
               Type Reapply and press Enter to optimize every green app again.
  unoptimize   Pick apps from a list and allow all of that again.
  autostart    Lists the apps that start themselves when the phone boots.
               Enter blocks one ([OFF], green) or allows it again ([ON]).
               Blocking uses Android's background restriction, the same
               switch optimize sets, so a blocked app also stops running in
               the background until you open it.
  permissions  Pick a permission (most important first), such as Camera,
               Location, Usage access or All files access. Apps that have it
               are green on top, apps that can get it are below. Enter takes
               it away or gives it, Tab marks several.
  cleanup      Pick a category: photos, videos, audio, documents, downloads,
               trash, SD card, all files, contacts, calendar, call log, SMS,
               apps, app data or settings. Then delete single items or use
               DELETE ALL. Files are overwritten before removal and skip the
               trash. Files and apps are listed biggest first, with sizes.
               The phone's screen lock is asked once, when the tool starts. Back up apps saves each app as a .zip in ~/phone-backups
               (the app, its Android/data and Android/obb files, optionally
               Android's own backup); Restore backups puts them back. Logins
               usually do not survive: without root, private data stays on
               the phone. Settings are sorted by type (Settings > Wi-Fi >
               DELETE ALL) and go back to their defaults.
               Flush free space sends TRIM, so the flash chip erases blocks
               freed by deleted files. Existing files are not touched.
               Keyboard learned words erases saved words and predictions.
               Screen lock & fingerprints removes the lock, and needs your
               current PIN, password or pattern.
               Uninstall anything (unsafe) lists every package, system parts
               and Google services included. Unsafe ones are marked and ask
               you to type the word REMOVE. For a preinstalled
               app the updates are deleted and it is removed for every user
               with its data; only its factory file stays in the read-only
               system image (deleting that needs root).
               Disable apps & services lists your apps first, then safe
               preinstalled extras, then system parts (not recommended).
               Critical system parts are hidden. Enter switches it off or
               back on. CUSTOM at the top lets you type a package name, and
               DISABLE ALL and ENABLE ALL do everything listed at once.
               System app data uses the same order.
               Close apps & free RAM closes apps and background services
               and keeps the ones you would notice losing.
               Notifications turns them off or on per app, or for all apps.
  store        Search F-Droid (open-source apps) on this computer and install
               the chosen apps. Picks the version that fits the phone,
               checks the download against F-Droid's checksum, installs it
               with adb. The Play Store app on the phone is not used.
  install FILE.apk
               Install an APK straight onto the phone over USB. Updates the
               app if it is already installed and keeps its data.
  help         Show this list.
SHEET
}

# The app list tool: optimize / unoptimize / autostart. fzf calls back into it as "$self _appops ...".
appops() {
mode="$1"
CACHE=/tmp/.appops_cache
OPS="RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND WAKE_LOCK START_FOREGROUND"
# autostart: Android 13+ stops delivering the boot broadcast to apps whose background use is restricted,
# and USB debugging may not switch off single boot receivers, so this one app-op is the autostart switch.
[ "$2" = "autostart" ] && OPS="RUN_ANY_IN_BACKGROUND"

# Friendly name for a package id. Known apps get their real name, others get the 2nd part of the id.
label() {
  case "$1" in
    com.discord) echo "Discord";;
    com.whatsapp) echo "WhatsApp";;
    org.thoughtcrime.securesms) echo "Signal";;
    com.instagram.android) echo "Instagram";;
    com.amazon.mShop.android.shopping) echo "Amazon Shopping";;
    com.google.android.youtube) echo "YouTube";;
    com.android.chrome) echo "Chrome";;
    com.zhiliaoapp.musically) echo "TikTok";;
    com.spotify.music) echo "Spotify";;
    com.netflix.mediaclient) echo "Netflix";;
    com.facebook.katana) echo "Facebook";;
    com.facebook.orca) echo "Messenger";;
    com.twitter.android) echo "X (Twitter)";;
    com.snapchat.android) echo "Snapchat";;
    org.telegram.messenger) echo "Telegram";;
    com.reddit.frontpage) echo "Reddit";;
    com.google.android.apps.maps) echo "Google Maps";;
    com.google.android.gm) echo "Gmail";;
    com.microsoft.teams) echo "Teams";;
    *) local n; n=$(echo "$1" | cut -d. -f2); echo "${n^}";;
  esac
}

# Preinstalled packages: "<tier> <package> <name>". 2 = safe to switch off,
# 3 = possible but not recommended. Installed apps are always tier 1.
# Any preinstalled package NOT listed here is tier 4 = never shown in optimize.
tiers() {
  cat <<'EOF'
2 com.android.chrome Chrome
2 com.android.egg Android Easter Egg
2 com.android.dreams.basic Screensavers
2 com.android.bips Print Service
2 com.android.printspooler Print Spooler
3 com.android.htmlviewer HTML Viewer
2 com.android.traceur System Tracing
2 com.android.wallpaper.livepicker Live Wallpaper Picker
2 com.android.hotwordenrollment.okgoogle Hey Google Enrollment
2 com.android.hotwordenrollment.xgoogle Hey Google Enrollment (X)
2 com.google.ambient.streaming Cross-Device Streaming
2 com.google.android.accessibility.switchaccess Switch Access
2 com.google.android.apps.bard Gemini
2 com.google.android.apps.docs Google Drive
2 com.google.android.apps.healthdata Health Connect
2 com.google.android.apps.maps Google Maps
2 com.google.android.apps.nbu.files Files by Google
2 com.google.android.apps.photos Google Photos
2 com.google.android.apps.restore Data Restore Tool
2 com.google.android.apps.tachyon Google Meet
2 com.google.android.apps.wellbeing Digital Wellbeing
2 com.google.android.apps.youtube.music YouTube Music
2 com.google.android.calculator Calculator
2 com.google.android.calendar Google Calendar
2 com.google.android.contacts Contacts
2 com.google.android.feedback Google Feedback
2 com.google.android.gm Gmail
2 com.google.android.gms.location.history Location History
2 com.google.android.gms.supervision Parental Controls
2 com.google.android.googlequicksearchbox Google App
2 com.google.android.keep Google Keep
2 com.google.android.marvin.talkback TalkBack
2 com.google.android.printservice.recommendation Print Recommendations
2 com.google.android.projection.gearhead Android Auto
2 com.google.android.tts Speech Services
2 com.google.android.videos Google TV
2 com.google.android.youtube YouTube
2 com.google.ar.core Google AR Services
2 com.nothing.agreement Nothing Agreement
2 com.nothing.aiwidget Nothing AI Widget
2 com.nothing.camera Nothing Camera
2 com.nothing.essentialintelligence Essential Space
2 com.nothing.experience Nothing Experience Program
2 com.nothing.gallery Nothing Gallery
2 com.nothing.introduction16 Nothing Introduction
2 com.nothing.logkit Nothing Log Kit
2 com.nothing.ntgamedashboard Game Dashboard
2 com.nothing.soundrecorder Nothing Recorder
2 com.nothing.universal.search Nothing Search
2 com.nothing.user.center Nothing Account
2 com.nothing.userguide Nothing User Guide
2 com.nothing.wallpaper Nothing Wallpapers
2 com.nothing.weather Nothing Weather
3 com.google.android.gms Google Play Services
3 com.google.android.gsf Google Services Framework
3 com.android.vending Play Store
3 com.google.android.configupdater Google Config Updater
3 com.google.android.partnersetup Google Partner Setup
3 com.google.android.setupwizard Setup Wizard
3 com.google.android.as Android System Intelligence
3 com.google.android.as.oss Private Compute Services
3 com.google.android.apps.turbo Device Health Services
3 com.google.android.apps.safetyhub Personal Safety
3 com.google.android.webview Android System WebView
3 com.google.android.inputmethod.latin Gboard (keyboard)
3 com.google.android.dialer Phone (calls)
3 com.google.android.apps.messaging Messages (SMS)
3 com.google.android.deskclock Clock (alarms)
3 com.google.android.documentsui Files Picker
3 com.google.android.captiveportallogin Wi-Fi Login Page
3 com.google.android.apps.carrier.carrierwifi Carrier Wi-Fi
3 com.google.android.tag NFC Tags
3 com.google.android.euicc eSIM Manager
3 com.google.android.cellbroadcastreceiver Emergency Alerts
3 com.android.settings Settings
3 com.android.settings.intelligence Settings Search
3 com.android.bluetooth Bluetooth
3 com.android.bluetoothmidiservice Bluetooth MIDI
3 com.android.nfc NFC
3 com.android.wifi.dialog Wi-Fi Dialogs
3 com.android.hotspot2.osulogin Wi-Fi Passpoint Login
3 com.android.vpndialogs VPN Dialogs
3 com.android.mtp USB File Transfer (MTP)
3 com.android.emergency Emergency Info
3 com.android.stk SIM Toolkit
3 com.android.storagemanager Storage Manager
3 com.android.companiondevicemanager Companion Device Manager
3 com.android.credentialmanager Credential Manager
3 com.android.managedprovisioning Work Profile Setup
3 com.android.providers.downloads Download Manager
3 com.nothing.applocker Nothing App Locker
3 com.nothing.appservice Nothing App Service
3 com.nothing.audioeffect Nothing Audio Effects
3 com.nothing.cardservice Nothing Card Service
3 com.nothing.customization.pixel Nothing Customization
3 com.nothing.glyphnotification Glyph Notifications
3 com.nothing.hearthstone Nothing Hearthstone
3 com.nothing.ntscreenshot Nothing Screenshot
3 com.nothing.OfflineOTAUpgradeApp Nothing Offline Update
3 com.nothing.smartcenter Nothing Smart Center
3 com.nothing.thirdparty Nothing Third-Party Service
2 com.netflix.mediaclient Netflix
2 com.netflix.partner.activation Netflix Activation
2 com.facebook.katana Facebook
2 com.linkedin.android LinkedIn
2 com.spotify.music Spotify
2 com.samsung.android.tvplus Samsung TV Plus
2 com.samsung.android.arzone AR Zone
2 com.samsung.android.app.spage Samsung Free
2 com.google.android.apps.subscriptions.red Google One
2 com.google.android.apps.magazines Google News
2 com.google.android.apps.podcasts Google Podcasts
2 com.facebook.appmanager Facebook App Manager
2 com.facebook.system Facebook App Installer
2 com.hiya.star Hiya Spam Protection
2 com.mygalaxy.service My Galaxy Service
2 com.android.dreams.phototable Photo Screensavers
2 com.android.devicediagnostics Device Diagnostics
2 com.android.DeviceAsWebcam Webcam Service
2 com.android.virtualization.terminal Linux Terminal
2 com.google.android.aicore Android AICore
2 com.google.android.apps.accessibility.voiceaccess Voice Access
2 com.google.android.syncadapters.calendar Google Calendar Sync
2 com.google.audio.hearing.visualization.accessibility.scribe Live Transcribe
2 com.samsung.android.calendar Samsung Calendar
2 com.samsung.android.app.notes Samsung Notes
2 com.samsung.android.app.clockface Clock Faces
2 com.samsung.android.game.gamehome Gaming Hub
2 com.samsung.android.goodlock Good Lock
2 com.samsung.android.oneconnect SmartThings
2 com.samsung.android.qstuner QuickStar
2 com.sec.android.app.popupcalculator Samsung Calculator
2 com.sec.android.app.voicenote Voice Recorder
2 com.samsung.android.app.contacts Samsung Contacts
2 com.samsung.android.app.interpreter Interpreter
2 com.samsung.android.app.moments Now Brief
2 com.samsung.android.app.routines Modes and Routines
2 com.samsung.android.app.sharelive Quick Share
2 com.samsung.android.app.sketchbook Sketchbook
2 com.samsung.android.app.clipboardedge Clipboard Edge Panel
2 com.samsung.android.app.taskedge Tasks Edge Panel
2 com.samsung.android.app.camera.sticker.facearavatar.preload AR Emoji Stickers
2 com.samsung.android.app.earphonetypec USB-C Earphones
2 com.samsung.android.aircommandmanager Air Command (S Pen)
2 com.samsung.android.service.aircommand Air Command Service (S Pen)
2 com.samsung.android.service.airviewdictionary Air View Dictionary
2 com.samsung.android.allshare.service.mediashare Nearby Media Sharing
2 com.samsung.android.beaconmanager SmartThings Find Beacons
2 com.samsung.android.bixby.agent Bixby Voice
2 com.samsung.android.bixby.wakeup Bixby Wake-up
2 com.samsung.android.carkey Digital Car Key
2 com.samsung.android.coldwalletservice Blockchain Keystore
2 com.samsung.android.dynamiclock Dynamic Lock Screen
2 com.samsung.android.easysetup Nearby Device Scanning
2 com.samsung.android.forest Samsung Digital Wellbeing
2 com.samsung.android.game.gametools Game Booster
2 com.samsung.android.game.gos Game Optimizing Service
2 com.samsung.android.mdecservice Calls and Texts on Other Devices
2 com.samsung.android.motionphoto.app Motion Photo
2 com.samsung.android.net.wifi.wifiguider Wi-Fi Tips
2 com.samsung.android.networkdiagnostic Network Diagnostics
2 com.samsung.android.photoremasterservice Photo Remaster
2 com.samsung.android.rubin.app Customization Service
2 com.samsung.android.secsoundpicker Sound Picker
2 com.samsung.android.app.soundpicker Sound Picker (app)
2 com.samsung.android.setting.multisound Separate App Sound
2 com.samsung.android.singletake.service Single Take
2 com.samsung.android.smartcallprovider Smart Call
2 com.samsung.android.callassistant Call Assist
2 com.samsung.android.smartmirroring Smart View
2 com.samsung.android.smartsuggestions Smart Suggestions
2 com.samsung.android.smartswitchassistant Smart Switch Assistant
2 com.sec.android.easyMover Smart Switch
2 com.sec.android.easyMover.Agent Smart Switch Agent
2 com.samsung.android.stickercenter Sticker Center
2 com.samsung.android.themestore Galaxy Themes
2 com.samsung.android.video Samsung Video Player
2 com.samsung.android.visionintelligence Bixby Vision
2 com.samsung.android.widget.pictureframe Picture Frame Widget
2 com.samsung.android.inputshare Multi Control
2 com.samsung.android.fast Secure Wi-Fi
2 com.samsung.android.accessibility.talkback Samsung TalkBack
2 com.samsung.accessory.budsunitemgr Galaxy Buds Manager
2 com.samsung.android.ipsgeofence Samsung Geofence
2 com.samsung.android.service.peoplestripe People Edge Panel
2 com.samsung.android.service.stplatform SmartThings Framework
2 com.samsung.android.service.tagservice Samsung Tags
2 com.samsung.android.dqagent Device Quality Agent
2 com.samsung.android.mcf.autohotspot Auto Hotspot
2 com.sec.mhs.smarttethering Auto Hotspot Tethering
2 com.samsung.app.newtrim Video Trimmer
2 com.samsung.gpuwatchapp GPU Watch
2 com.samsung.mediasearch Media Search
2 com.samsung.petservice Pet Service
2 com.samsung.safetyinformation Safety Information
2 com.samsung.SMT Samsung Text-to-Speech
2 com.samsung.storyservice Gallery Stories
2 com.sec.android.app.billing Samsung Checkout
2 com.sec.android.app.camera Samsung Camera
2 com.sec.android.app.magnifier Magnifier
2 com.sec.android.app.myfiles My Files
2 com.sec.android.app.samsungapps Galaxy Store
2 com.sec.android.app.vepreload Video Editor
2 com.sec.android.daemonapp Samsung Weather
2 com.sec.android.diagmonagent Diagnostics Agent
2 com.sec.android.easyonehand One-Handed Mode
2 com.sec.android.gallery3d Samsung Gallery
2 com.sec.android.mimage.photoretouching Photo Editor
2 com.sec.android.widgetapp.easymodecontactswidget Easy Mode Contacts Widget
2 com.sec.hearingadjust Adapt Sound
3 com.sec.android.app.clockpackage Samsung Clock (alarms)
3 com.samsung.android.dialer Samsung Phone (calls)
3 com.samsung.android.honeyboard Samsung Keyboard
3 com.samsung.android.app.smartcapture Screenshot Tools
3 com.samsung.android.app.aodservice Always On Display
3 com.samsung.android.app.dressroom Wallpaper and Style
3 com.samsung.android.app.updatecenter Update Center
3 com.samsung.android.bluelightfilter Eye Comfort Shield
3 com.samsung.android.fmm Find My Mobile
3 com.samsung.android.lool Device Care
3 com.samsung.android.sm.devicesecurity Device Security
3 com.sec.android.sdhms Device Health Manager
3 com.samsung.android.mcfds Samsung Continuity Service
3 com.samsung.android.mcfserver Samsung Multi Connectivity
3 com.samsung.android.mdx.kit Link to Windows Service
3 com.samsung.android.mobileservice Samsung Experience Service
3 com.osp.app.signin Samsung Account
3 com.samsung.android.mtp Samsung USB File Transfer (MTP)
3 com.samsung.android.nfc Samsung NFC
3 com.android.apps.tag NFC Tags
3 com.android.stk2 SIM Toolkit 2
3 com.samsung.android.privacydashboard Privacy Dashboard
3 com.samsung.android.scpm Samsung Cloud Platform Manager
3 com.samsung.android.scs Samsung Core Services
3 com.samsung.android.aicore Samsung AI Core
3 com.samsung.android.spayfw Samsung Pay Framework
3 com.samsung.android.themecenter Theme Engine
3 com.samsung.android.wifi.intelligence Intelligent Wi-Fi
3 com.samsung.android.emergency Samsung Emergency Info
3 com.sec.android.app.safetyassurance Emergency SOS
3 com.samsung.accessibility Samsung Accessibility
3 com.samsung.faceservice Face Service
3 com.samsung.knox.securefolder Secure Folder
3 com.sec.android.app.bluetoothagent Bluetooth Agent
3 com.sec.android.app.SecSetupWizard Samsung Setup Wizard
3 com.sec.android.app.soundalive Sound Quality and Effects
3 com.sec.android.soagent Software Update Agent
3 com.wssyncmldm Software Update
3 com.sec.spp.push Samsung Push Service
3 com.sec.unifiedwfc Wi-Fi Calling
2 proton.android.authenticator Proton Authenticator
2 proton.android.pass Proton Pass
2 com.google.android.contactkeys Android System Key Verifier
2 com.google.android.safetycore Android System SafetyCore
2 com.samsung.android.bixby.ondevice.dede Bixby On-Device German
2 com.samsung.android.bixby.ondevice.enus Bixby On-Device English
2 com.samsung.android.nmt.apps.t2t.languagepack.ende Translation Pack English-German
2 com.samsung.android.ssco Samsung Smart Suggestions Core
2 com.google.android.apps.aiwallpapers AI Wallpaper
2 com.google.android.glasses.core Glasses Core
2 com.samsung.android.samsungpassautofill Autofill with Samsung Pass
2 com.samsung.android.samsungpass Samsung Pass
2 com.samsung.android.da.daagent Dual Messenger
2 com.monotype.android.font.foundation Foundation Font
2 com.samsung.android.aremoji Galaxy Avatar
2 com.microsoft.appmanager Link to Windows
2 com.samsung.android.mdx Link to Windows Service
2 com.facebook.services Meta Services
2 com.microsoft.skydrive OneDrive
2 com.samsung.android.app.parentalcare Parental Controls
2 com.samsung.android.scloud Samsung Cloud
2 com.samsung.android.kidsinstaller Samsung Kids Installer
2 com.samsung.android.dkey Samsung Wallet Digital Key
2 com.samsung.android.hwresourceshare.storage Storage Share
2 com.samsung.android.app.watchmanagerstub Wearable Manager Installer
EOF
}

# Sub-commands of the app list tool:
#   tiers  print the app table      build  read app state from the phone into the cache
#   show   print the cached list    apply  optimize/unoptimize/toggle the selected apps
#   menu   open the fzf picker
case "$mode" in
  tiers) tiers;;  # the cleanup tool reads the same table
  build)
    all=$(adb shell pm list packages | tr -d '\r' | sed 's/^package://' | sort)
    if [ "$2" = "autostart" ]; then  # only apps that ask to be started at boot
      boot=$(for a in BOOT_COMPLETED LOCKED_BOOT_COMPLETED; do
               adb shell cmd package query-receivers --brief -a android.intent.action.$a --include-stopped-packages </dev/null
             done | tr -d '\r ' | grep / | cut -d/ -f1 | sort -u)
      all=$(comm -12 <(echo "$all") <(echo "$boot"))
    fi
    declare -A USER TIER NAME
    # installed by the user: "-3", plus every package that is not a system package (some phones leave apps out of "-3")
    sys_pkgs=$(adb shell pm list packages -s | tr -d '\r' | sed 's/^package://' | sort)
    for p in $(adb shell pm list packages -3 | tr -d '\r' | sed 's/^package://') $(comm -23 <(echo "$all") <(echo "$sys_pkgs")); do USER[$p]=1; done
    while read -r t p n; do TIER[$p]=$t; NAME[$p]=$n; done < <(tiers)
    full="$all"
    for op in $OPS; do
      ign=$(adb shell cmd appops query-op "$op" ignore | tr -d '\r' | grep -E '^[[:space:]]*[A-Za-z0-9_.]+$' | tr -d ' ' | sort)
      full=$(comm -12 <(echo "$full") <(echo "$ign"))
    done
    declare -A F
    for p in $full; do F[$p]=1; done
    # cache line: tier|G or W|Name (package), sorted by tier then name
    for p in $all; do
      if [ -n "${USER[$p]}" ]; then t=1; else t=${TIER[$p]:-4}; fi
      [ -n "${F[$p]}" ] && st=G || st=W
      printf '%s|%s|%s (%s)\n' "$t" "$st" "${NAME[$p]:-$(label "$p")}" "$p"
    done | sort -f -t'|' -k1,1 -k3 > "$CACHE"
    ;;
  show)
    want="$2"
    last=
    # typing "Reapply" in the search bar leaves just this row; Enter on it redoes every green app
    [ "$want" = "optimize" ] && printf '\033[1;35mReapply - optimize every green app again\033[0m\n'
    while IFS='|' read -r t st line; do
      # optimize hides tier 4; unoptimize shows whatever is optimized, so nothing gets stuck
      if [ "$want" = "unoptimize" ]; then [ "$st" = G ] || continue; else [ "$t" = 4 ] && continue; fi
      if [ "$want" = "autostart" ]; then [ "$st" = G ] && line="[OFF] $line" || line="[ON]  $line"; fi
      if [ "$t" != "$last" ]; then
        last=$t
        case "$t" in
          1) h="YOUR APPS - safe";;
          2) h="PREINSTALLED EXTRAS - safe";;
          3) h="SYSTEM PARTS - possible, NOT recommended";;
          4) h="CRITICAL SYSTEM - turn these back on";;
        esac
        printf '\033[1;36m----- %s -----\033[0m\n' "$h"
      fi
      if [ "$st" = "G" ]; then
        printf '\033[32m%s\033[0m\n' "$line"
      elif [ "$t" = 3 ]; then
        printf '\033[33m%s\033[0m\n' "$line"
      else
        printf '%s\n' "$line"
      fi
    done < "$CACHE"
    ;;
  apply)
    want="$2"
    [ "$want" = "optimize" ] && value=ignore || value=allow
    [ "$want" = "optimize" ] && st=G || st=W
    # one argument per selected line (Tab), or just the line under the cursor
    for sel in "${@:3}"; do
      line=$(echo "$sel" | sed 's/\x1b\[[0-9;]*m//g')
      if [ "$want" = "optimize" ] && [ "${line%% *}" = "Reapply" ]; then
        mapfile -t green < <(grep '^.|G|' "$CACHE" | cut -d'|' -f3-)
        [ "${#green[@]}" -gt 0 ] && "$self" _appops apply optimize "${green[@]}"
        continue
      fi
      case "$line" in *")") ;; *) continue;; esac  # section header, not an app
      pkg=$(echo "$line" | sed 's/.*(\(.*\))$/\1/')
      if [ "$want" = "autostart" ]; then  # toggle: [ON] rows get blocked, [OFF] rows get allowed again
        case "$line" in "[OFF]"*) value=allow; st=W;; *) value=ignore; st=G;; esac
      fi
      # one adb call per app, 8 apps at a time, so Reapply on 100+ apps takes seconds
      # standby bucket is not part of "green": Android lifts it while the app is open and drops it again afterwards
      if [ "$want" = "optimize" ]; then extra="am force-stop $pkg; am set-standby-bucket $pkg restricted"
      elif [ "$want" = "autostart" ]; then extra=":"
      else extra="am set-standby-bucket $pkg active"; fi
      adb shell "for op in $OPS; do cmd appops set $pkg \$op $value; done; $extra" </dev/null >/dev/null 2>&1 &
      (( ++jobs % 8 == 0 )) && wait
      esc=$(echo "$pkg" | sed 's/\./\\./g')
      sed -i "s/^\(.\)|.|\(.*(${esc})\)\$/\1|${st}|\2/" "$CACHE"
    done
    wait
    ;;
  menu)
    want="$2"
    # several phones plugged in: choose one; every adb call below inherits it
    if [ -z "$ANDROID_SERIAL" ]; then
      devs=$(adb devices | awk 'NR>1 && $2=="device"{print $1}')
      [ -z "$devs" ] && { echo "No phone connected (check USB debugging)."; exit 1; }
      if [ "$(echo "$devs" | wc -l)" -gt 1 ]; then
        ANDROID_SERIAL=$(for d in $devs; do echo "$d  $(adb -s "$d" shell getprop ro.product.model </dev/null | tr -d '\r')"; done \
          | fzf --height=40% --reverse --prompt="phone > " --header="Which phone?" | cut -d' ' -f1)
        [ -z "$ANDROID_SERIAL" ] && exit 0
      fi
      export ANDROID_SERIAL
    fi
    echo "Loading apps..."
    "$self" _appops build "$want"
    echo 0 > /tmp/.appops_pos
    header="Green = fully optimized | Yellow = not recommended | Tab = select several | Enter = $want all selected | type Reapply + Enter = redo all green | Ctrl-R = refresh | Esc = close"
    [ "$want" = "autostart" ] && header="[ON] = starts when the phone boots | Green [OFF] = blocked | Enter = switch | Tab = select several | Ctrl-R = refresh | Esc = close"
    "$self" _appops show "$want" | fzf --ansi --multi --height=60% --reverse --prompt="$want > " \
      --header="$header" \
      --bind "enter:execute-silent(echo {n} > /tmp/.appops_pos; $self _appops apply $want {+})+reload($self _appops show $want)" \
      --bind "ctrl-r:reload($self _appops build $want; $self _appops show $want)" \
      --bind 'load:transform:echo "pos($(( $(cat /tmp/.appops_pos) + 1 )))"'
    ;;
esac
}

# The cleanup / permissions / battery tool (Python). It is written to a temp file and run from there,
# so the keyboard stays on stdin (this also works on Windows, where /dev/fd does not exist for Python).
# PYTHON is set by the Windows .bat; on Linux it is python3. -X utf8 keeps app names readable on Windows.
cleanup() {
local py rc
py=$(mktemp) || return 1
cat > "$py" <<'PY'
#!/usr/bin/env python3
"""cleanup: choose what to permanently delete from the USB-connected phone."""
import getpass
import hashlib
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

# Cleanup categories for files: name -> regex the file path must match.
FILE_CATEGORIES = {
    "Photos": r"\.(jpe?g|png|gif|webp|hei[cf]|dng|bmp|avif)$",
    "Videos": r"\.(mp4|mkv|mov|avi|webm|3gp|m4v)$",
    "Audio": r"\.(mp3|m4a|aac|ogg|opus|flac|wav|amr)$",
    "Documents": r"\.(pdf|docx?|xlsx?|pptx?|odt|txt|csv|rtf|epub)$",
    "Downloads": r"^/(sdcard|storage/[^/]+)/+Download/",
    # Deleting from a gallery only moves files here, so these must be wipeable too.
    "Trash & thumbnails": r"/\.(trash|thumbnails)|/\.trashed-",
    "SD card": r"^/storage/",
    "All files": r"",
}

CONTACTS_URI = "content://com.android.contacts/contacts"
SMS_URI = "content://sms"

# Each is (uri, projection, label fields, note shown on entry, filter for live rows).
CONTENT_CATEGORIES = {
    "Contacts": (CONTACTS_URI, "_id:display_name", ["display_name"],
                 "Synced contacts are also deleted from their account (Google, Samsung).", ""),
    # Synced events stay as deleted=1 rows until the next sync, so those count as gone.
    "Calendar": ("content://com.android.calendar/events", "_id:title:dtstart", ["title", "dtstart"],
                 "Synced events are also deleted from their account.", "deleted=0"),
    "Call log": ("content://call_log/calls", "_id:number:date", ["number", "date"], "", ""),
    "SMS": (SMS_URI, "_id:address:date:body", ["address", "date", "body"],
            "RCS chats are not stored here.", ""),
}

# Settings are grouped by matching their key name against these regexes.
SETTING_CATEGORIES = {
    "Wi-Fi": r"wifi|wlan",
    "Bluetooth": r"bluetooth|^ble_",
    "Mobile data & network": r"mobile_data|data_roaming|airplane|network|apn|hotspot|tether|vpn|dns",
    "Location": r"location|gps",
    "Sound & vibration": r"volume|sound|ringtone|ringer|vibrat|haptic|dtmf|zen_",
    "Display": r"display|screen|brightness|font|night|dark|rotation|wallpaper",
    "Notifications": r"notification",
    "Battery & power": r"battery|power",
    "Accessibility": r"accessibility",
    "Date & time": r"auto_time|time_12|time_zone|timezone",
}
SETTINGS_OTHER = "Other (no delete all)"

# Resetting these can cut USB debugging, trap the phone in setup, or break unlock and typing.
PROTECTED_SETTINGS = re.compile(
    r"adb|development_settings|provisioned|user_setup|setup_wizard|android_id|input_method"
    r"|lock|boot|verifier|bluetooth_address|bluetooth_name|device_name|multi_sim|^sim_|subscription",
    re.I,
)

# Clearing these can break calling, unlocking or the USB connection itself.
PROTECTED_APPS = re.compile(r"^android$|providers\.(settings|telephony)|shell|systemui|keyguard|permissioncontroller|setupwizard|provision"
                            r"|^com\.android\.phone$|packageinstaller|launcher|com\.miui\.(home|securitycenter)")

LABEL_CACHE = os.path.expanduser("~/.cache/phone-cleanup-labels.json")
PERMISSION_CACHE = os.path.expanduser("~/.cache/phone-cleanup-permission-requests.json")
EXCEPTIONS_FILE = os.path.expanduser("~/.config/phone-cleanup-exceptions.json")
CONTENT_BATCH = 200


# Raised when the phone answers a query with an error instead of data.
class PhoneError(Exception):
    pass


def adb(command):
    """Run one command string in the phone's shell. Quote every value with shlex.quote."""
    r = subprocess.run(["adb", "shell", command], capture_output=True, text=True, errors="replace")
    return r.returncode, r.stdout.replace("\r", ""), r.stderr.replace("\r", "")


# Stop early with a clear message if no phone is connected or USB debugging is not accepted.
def require_phone():
    r = subprocess.run(["adb", "get-state"], capture_output=True, text=True)
    if r.stdout.strip() != "device":
        sys.exit("No usable phone: " + (r.stderr.strip() or r.stdout.strip())
                 + "\nConnect one phone by USB and accept the USB debugging prompt.")
    print("Connected phone:", adb("getprop ro.product.model")[1].strip())


def pick(prompt, labels, header, multi=False, ansi=False):
    """Return chosen indexes from fzf, or None on Esc."""
    lines = "\n".join(f"{i}\t{re.sub(r'[\t\n]', ' ', label)}" for i, label in enumerate(labels))
    cmd = ["fzf", "--height=60%", "--reverse", f"--prompt={prompt} > ", f"--header={header}",
           "--delimiter=\t", "--with-nth=2.."]
    r = subprocess.run(cmd + (["--multi"] if multi else []) + (["--ansi"] if ansi else []), input=lines, stdout=subprocess.PIPE, text=True)
    if r.returncode != 0:
        return None
    return [int(line.split("\t", 1)[0]) for line in r.stdout.splitlines()]


# input() that treats Ctrl-D as an empty answer instead of crashing.
def ask(question):
    try:
        return input(question).strip()
    except EOFError:
        return ""


# --- files ---

def matches_category(pattern, path):
    return re.search(pattern, path, re.I) is not None


# Mount points of SD cards / USB sticks (everything in /storage except internal storage).
def sd_cards():
    _, out, _ = adb("ls /storage 2>/dev/null")
    return [f"/storage/{name}/" for name in out.split() if name not in ("emulated", "self")]


# List every file on internal storage and SD cards whose path matches the category regex.
def load_files(pattern):
    """Matching files on internal storage and SD cards, biggest first, with their size."""
    roots = " ".join(shlex.quote(root) for root in ["/sdcard/"] + sd_cards())
    _, out, _ = adb(f"find {roots} -type f -exec stat -c '%s %n' {{}} + 2>/dev/null")
    found = []
    for line in out.splitlines():
        size, _, path = line.partition(" ")
        if size.isdigit() and path and matches_category(pattern, path):
            found.append((int(size), path))
    found.sort(key=lambda f: (-f[0], f[1]))
    return [(path, f"{fmt_size(size):>8}  {re.sub(r'^/sdcard/+', '', path)}") for size, path in found]


# Prints "<index> <status>" per file: 0 done, 1 still there, 3 removed but not overwritten first.
WIPE_FUNCTION = """w() {
  n=$(stat -c %s "$2") || { echo "$1 1"; return; }
  if [ "$n" -ge 1048576 ]; then b=1048576; else b=4096; fi
  dd if=/dev/urandom of="$2" bs=$b count=$(( (n + b - 1) / b )) conv=notrunc 2>/dev/null; d=$?
  rm -f "$2"
  if [ -e "$2" ]; then echo "$1 1"; elif [ "$d" -ne 0 ]; then echo "$1 3"; else echo "$1 0"; fi
}
"""
WIPE_CONNECTIONS = 4


def wipe_files(paths, progress):
    """Overwrite and remove files over a few long-lived shells. Returns the paths that remain."""
    results = {}

    def run(batch):
        # A file as stdin avoids a pipe deadlock: the script can be far larger than the pipe buffer.
        with tempfile.TemporaryFile("w+") as script:
            script.write(WIPE_FUNCTION + "".join(f"w {i} {shlex.quote(paths[i])}\n" for i in batch))
            script.flush()
            script.seek(0)
            proc = subprocess.Popen(["adb", "shell", "sh"], stdin=script, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, errors="replace")
            for line in proc.stdout:
                m = re.fullmatch(r"(\d+) (\d)\s*", line)
                if m:
                    results[int(m[1])] = int(m[2])
                    progress()
            proc.wait()

    indexes = list(range(len(paths)))
    with ThreadPoolExecutor(WIPE_CONNECTIONS) as pool:
        list(pool.map(run, [indexes[i::WIPE_CONNECTIONS] for i in range(WIPE_CONNECTIONS)]))
    for i, status in results.items():
        if status == 3:
            print(f"\n  Removed, but could not overwrite first: {paths[i]}")
    # A dropped connection leaves files unreported, and those count as failed.
    return [path for i, path in enumerate(paths) if results.get(i, 1) == 1]


# --- contacts, call log, SMS ---

# Turn 'content query' output ("Row: 0 a=1, b=2") into a list of dicts.
def parse_rows(text):
    rows = []
    for line in text.splitlines():
        m = re.match(r"Row: \d+ (.*)", line)
        if m:
            rows.append(dict(re.findall(r"(\w+)=(.*?)(?=, \w+=|$)", m.group(1))))
    return rows


# One readable line for a contact/SMS/call/event, with timestamps turned into dates.
def content_label(row, fields):
    parts = []
    for field in fields:
        value = row.get(field, "")
        if field in ("date", "dtstart") and value.isdigit():
            value = datetime.fromtimestamp(int(value) / 1000).strftime("%Y-%m-%d %H:%M")
        parts.append(value)
    return "  ".join(parts)


# Read rows (id, label) from an Android content provider such as contacts or SMS.
def load_content(uri, projection, fields, where=""):
    query = f" --where {shlex.quote(where)}" if where else ""
    code, out, err = adb(f"content query --uri {uri} --projection {projection}{query}")
    if "Row:" not in out and "No result found" not in out:
        raise PhoneError((err or out).strip().splitlines()[0] if (err or out).strip() else f"exit {code}")
    return [(row["_id"], content_label(row, fields)) for row in parse_rows(out) if "_id" in row]


def delete_rows(uri, condition):
    """Delete rows whose id matches condition, such as "=5" or " IN (5,6)"."""
    # The contacts table accepts deletes but ignores them, so delete its raw contacts instead.
    target, key = ("content://com.android.contacts/raw_contacts", "contact_id") if uri == CONTACTS_URI else (uri, "_id")
    delete = f"content delete --uri {target} --where {shlex.quote(key + condition)}"
    # Android silently ignores SMS writes from the shell unless this permission is allowed.
    adb(f"appops set com.android.shell WRITE_SMS allow; {delete}; appops set com.android.shell WRITE_SMS default"
        if uri == SMS_URI else delete)


def delete_content(uri, row_id, live=""):
    where = f"_id={row_id}"
    delete_rows(uri, f"={row_id}")
    check = shlex.quote(f"{where} AND {live}" if live else where)
    # Only an explicit empty result counts: a permission error also returns no rows.
    _, out, _ = adb(f"content query --uri {uri} --projection _id --where {check}")
    return "No result found" in out


def delete_content_many(uri, ids, live, progress):
    """Delete rows in batches, retrying leftovers singly. Returns the ids that remain."""
    failed = []
    for start in range(0, len(ids), CONTENT_BATCH):
        batch = ids[start:start + CONTENT_BATCH]
        where = f"_id IN ({','.join(batch)})"
        delete_rows(uri, f" IN ({','.join(batch)})")
        check = shlex.quote(f"{where} AND {live}" if live else where)
        _, out, _ = adb(f"content query --uri {uri} --projection _id --where {check}")
        # A permission error also returns no rows, so only an explicit empty result clears the batch.
        left = [] if "No result found" in out else [
            row["_id"] for row in parse_rows(out) if "_id" in row] if "Row:" in out else batch
        failed += [row_id for row_id in left if not delete_content(uri, row_id, live)]
        progress(len(batch))
    return failed


# --- apps ---

# Installed packages. "-3" = apps you installed, "-s" = preinstalled system apps.
def user_packages(flags=""):
    """Apps installed by the user: "-3", plus every package that is not a system package,
    because some phones leave user-installed apps out of "-3"."""
    user = package_names(adb(f"pm list packages -3 {flags}")[1])
    return user | (package_names(adb(f"pm list packages {flags}")[1]) - package_names(adb(f"pm list packages -s {flags}")[1]))


def fmt_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000:
            return f"{n:.0f} {unit}" if unit == "B" or n >= 100 else f"{n:.1f} {unit}"
        n /= 1000
    return f"{n:.1f} TB"


def app_sizes():
    """{package: app + data + cache bytes} from Android's last storage check ("dumpsys diskstats")."""
    out = adb("dumpsys diskstats")[1]

    def arr(key):
        m = re.search(rf"^{key}: (\[.*\])", out, re.M)
        try:
            return json.loads(m[1]) if m else []
        except ValueError:
            return []
    sizes = zip(arr("App Sizes"), arr("App Data Sizes"), arr("Cache Sizes"))
    return {p: sum(x or 0 for x in s) for p, s in zip(arr("Package Names"), sizes)}


def load_apps(scope="-3"):
    """Apps you installed, biggest first, with name and size. Other scopes ("-s") just list package names."""
    if scope != "-3":
        _, out, _ = adb(f"pm list packages {scope}")
        return [(p, p) for p in sorted(line[8:] for line in out.splitlines() if line.startswith("package:"))]
    packages, sizes = user_packages(), app_sizes()
    apks = parse_package_paths(adb("pm list packages -f")[1])
    labels = load_labels({p: apks[p] for p in packages if p in apks})
    order = sorted(packages, key=lambda p: (-sizes.get(p, 0), p))
    return [(p, f"{fmt_size(sizes[p]) if p in sizes else '':>8}  {labels.get(p) or p} ({p})") for p in order]


# Uninstall one app. Returns True on success.
def delete_app(package):
    _, out, _ = adb(f"pm uninstall {shlex.quote(package)}")
    return "Success" in out


def load_system_apps():
    """Safe preinstalled apps first, then the not recommended ones. Unlisted (critical) ones stay hidden."""
    tiers = load_tiers()
    apps = [(tiers[p][0], tiers[p][1], p) for p, _ in load_apps("-s") if p in tiers and not PROTECTED_APPS.search(p)]
    return [(p, f"{'[not recommended] ' if tier == 3 else ''}{name} ({p})")
            for tier, name, p in sorted(apps, key=lambda a: (a[0], a[1].casefold()))]


# Erase an app's data (like Settings > Apps > Clear storage). Returns True on success.
def clear_app_data(package):
    _, out, _ = adb(f"pm clear {shlex.quote(package)}")
    return "Success" in out


# --- free space ---

# Ask Android to TRIM free space so the flash chip erases blocks of deleted files.
def flush_free_space():
    print("Sending TRIM for internal storage. Existing files are not touched.")
    code, out, err = adb("sm fstrim")
    if code == 0 and "Exception" not in out + err:
        print("TRIM accepted. The flash chip now knows the freed blocks are unused and erases them on its own")
        print("schedule, so leave the phone on and charging for a while. Android does not report when it finishes.")
    else:
        print(f"TRIM refused: {(err or out).strip()[:200]}")


# --- app names: Android has no shell command for them, so they are read from each APK ---

# Little-endian readers for the binary APK formats below.
def u16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


# Walk the (type, offset, size) chunks of Android's binary XML / resource table format.
def chunks(data, start, end):
    while start + 8 <= end:
        size = u32(data, start + 4)
        if size < 8:
            return
        yield u16(data, start), start, size
        start += size


# Read string number 'index' from a string pool chunk (UTF-8 or UTF-16).
def pool_string(data, pool, index):
    count, _, flags, strings = struct.unpack_from("<IIII", data, pool + 8)
    if index >= count:
        raise IndexError(index)
    at = pool + strings + u32(data, pool + u16(data, pool + 2) + index * 4)
    if flags & 0x100:  # UTF-8: character count, then byte count
        at += 2 if data[at] & 0x80 else 1
        length = data[at]
        if length & 0x80:
            length = (length & 0x7F) << 8 | data[at + 1]
            at += 1
        return data[at + 1:at + 1 + length].decode("utf-8", "replace")
    length = u16(data, at)
    if length & 0x8000:
        length = (length & 0x7FFF) << 16 | u16(data, at + 2)
        at += 2
    return data[at + 2:at + 2 + length * 2].decode("utf-16-le", "replace")


def manifest_label(data):
    """Return the <application> label: text, a resource id, or None."""
    pool, resource_ids = None, ()
    for kind, at, size in chunks(data, u16(data, 2), len(data)):
        if kind == 0x0001:
            pool = at
        elif kind == 0x0180:
            resource_ids = struct.unpack_from(f"<{(size - 8) // 4}I", data, at + 8)
        elif kind == 0x0102 and pool_string(data, pool, u32(data, at + 20)) == "application":
            first = at + 16 + u16(data, at + 24)
            for i in range(u16(data, at + 28)):
                attr = first + i * u16(data, at + 26)
                name = u32(data, attr + 4)
                # 0x01010001 is android:label; shrunk APKs may strip the plain attribute name.
                if (name < len(resource_ids) and resource_ids[name] == 0x01010001) or (
                        name >= len(resource_ids) and pool_string(data, pool, name) == "label"):
                    kind = data[attr + 15]
                    if kind == 3:
                        return pool_string(data, pool, u32(data, attr + 8))
                    return u32(data, attr + 16) if kind == 1 else None
            return None
    return None


def entry_offset(data, table, entry):
    """Return an entry's offset inside a resource type chunk, or None if it is absent there."""
    flags, count = data[table + 9], u32(data, table + 12)
    index = table + u16(data, table + 2)
    if flags & 1:  # sparse: (entry, offset / 4) pairs
        for i in range(count):
            if u16(data, index + i * 4) == entry:
                return u16(data, index + i * 4 + 2) * 4
        return None
    if entry >= count:
        return None
    if flags & 2:  # 16-bit offsets / 4
        offset = u16(data, index + entry * 2)
        return None if offset == 0xFFFF else offset * 4
    offset = u32(data, index + entry * 4)
    return None if offset == 0xFFFFFFFF else offset


def resource_string(data, resource, language, depth=0):
    """Resolve a string resource, preferring the phone's language, then the default."""
    pool, best, best_rank = None, None, None
    package_id, type_id, entry = resource >> 24, resource >> 16 & 0xFF, resource & 0xFFFF
    for kind, at, size in chunks(data, u16(data, 2), len(data)):
        if kind == 0x0001:
            pool = at
        elif kind == 0x0200 and u32(data, at + 8) == package_id:
            for sub, table, _ in chunks(data, at + u16(data, at + 2), at + size):
                if sub != 0x0201 or data[table + 8] != type_id:
                    continue
                offset = entry_offset(data, table, entry)
                if offset is None:
                    continue
                item = table + u32(data, table + 16) + offset
                flags = u16(data, item + 2)
                if flags & 8:  # compact entry
                    value = (flags >> 8, u32(data, item + 4))
                elif flags & 1:  # complex entries are not strings
                    continue
                else:
                    value_at = item + u16(data, item)
                    value = (data[value_at + 3], u32(data, value_at + 4))
                locale = data[table + 28:table + 30]
                rank = 0 if locale == language else 1 if locale == b"\0\0" else 2
                if best is None or rank < best_rank:
                    best, best_rank = value, rank
    if best is None:
        return None
    if best[0] == 3:
        return pool_string(data, pool, best[1])
    return resource_string(data, best[1], language, depth + 1) if best[0] == 1 and depth < 4 else None


# Like adb(), but returns raw bytes (used to pull files out of APKs).
def adb_bytes(command):
    return subprocess.run(["adb", "exec-out", command], capture_output=True).stdout


# The app's display name, read straight from its APK on the phone. Empty if it cannot be read.
def read_label(apk, language):
    quoted = shlex.quote(apk)
    try:
        label = manifest_label(adb_bytes(f"unzip -p {quoted} AndroidManifest.xml 2>/dev/null"))
        if isinstance(label, int):
            label = resource_string(adb_bytes(f"unzip -p {quoted} resources.arsc 2>/dev/null"), label, language)
        return (label or "").strip()
    except (struct.error, IndexError, ValueError):
        return ""  # the package id is shown instead


def load_labels(apks):
    """Map package to name for {package: apk path}. An empty name means none was found."""
    # shortcut: cached by APK path, so a phone language change keeps old names until the cache is deleted.
    try:
        with open(LABEL_CACHE) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    missing = [pkg for pkg, apk in apks.items() if cache.get(pkg, {}).get("apk") != apk]
    language = adb("getprop persist.sys.locale")[1].strip()[:2].encode().ljust(2, b"\0")
    try:
        with ThreadPoolExecutor(4) as pool:
            for i, (pkg, label) in enumerate(
                    zip(missing, pool.map(lambda pkg: read_label(apks[pkg], language), missing)), 1):
                cache[pkg] = {"apk": apks[pkg], "label": label}
                print(f"\rReading app names {i}/{len(missing)} (first run is the slowest)   ", end="", flush=True)
    finally:
        if missing:
            print()
        os.makedirs(os.path.dirname(LABEL_CACHE), exist_ok=True)
        with open(LABEL_CACHE, "w") as f:
            json.dump(cache, f)
    return {pkg: cache[pkg]["label"] for pkg in apks}


# --- keyboard data ---

# Package names from 'ime list' (installed keyboards).
def parse_ime_packages(text):
    return sorted({line.split("/")[0].strip() for line in text.splitlines() if "/" in line})


# Keyboards plus the user dictionary: clearing their data erases learned words.
def load_keyboards():
    packages = parse_ime_packages(adb("ime list -a -s")[1]) + ["com.android.providers.userdictionary"]
    apks = parse_package_paths(adb("pm list packages -f")[1])
    labels = load_labels({p: apks[p] for p in packages if p in apks})
    return [(p, f"{labels[p]} ({p})" if labels[p] else p) for p in packages if p in apks]


# --- screen lock ---

# Remove the screen lock after two confirmations. Needs the current PIN/password/pattern.
def lock_menu():
    print("This removes the screen lock (PIN, pattern or password). Android then deletes the fingerprints")
    print("and face unlock tied to it, and apps lose keys protected by the lock, so banking or wallet apps")
    print("may need setting up again. Anyone holding the phone can then open it.")
    print("It needs your current lock. A pattern is entered as digits, 1 to 9 from top left to bottom right.")
    if ask("Type REMOVE to continue: ") != "REMOVE":
        print("Cancelled.")
        return
    try:
        current = getpass.getpass("Current PIN, password or pattern digits (hidden, empty cancels): ")
    except EOFError:
        current = ""
    if not current:
        print("Cancelled.")
        return
    code, out, err = adb(f"locksettings clear --old {shlex.quote(current)}")
    if code == 0 and "cleared" in out.lower():
        print("Screen lock removed. Check Settings > Fingerprint to confirm the fingerprints are gone.")
    else:
        print(f"Not removed: {(out or err).strip()[:200]}")
        print("Wrong entries count as failed unlock attempts, so stop and check before trying again.")


# --- screen lock check ---

def verify_lock(why):
    """Ask for the phone's screen lock (hidden) and let the phone check it. True when it is right.
    The phone's answer can repeat the code, so it is never printed."""
    while True:
        try:
            code = getpass.getpass(f"{why} Screen lock (hidden; a pattern as digits 1-9; just Enter if the phone has none; Ctrl-C cancels): ")
        except (EOFError, KeyboardInterrupt):
            print("\nCancelled.")
            return False
        _, out, err = adb(f"locksettings verify --old {shlex.quote(code)}" if code else "locksettings verify")
        if re.search("verified successfully", out + err, re.I):
            return True
        if re.search(r"unknown command|usage:", out + err, re.I) and not re.search("didn't match|wrong", out + err, re.I):
            print("This phone cannot check its screen lock over USB, so it is not asked.")
            return True
        print("Too many wrong tries: the phone makes you wait. Try again later." if re.search("throttl|try again", out + err, re.I)
              else "Wrong screen lock. Wrong tries count as failed unlock attempts on the phone.")


# --- disable apps and services ---

# Set of package names from 'pm list packages' output.
def package_names(text):
    return {line[8:] for line in text.splitlines() if line.startswith("package:")}


def disabled_packages():
    """Packages that are off: disabled, or removed for this user but still on the phone."""
    off = package_names(adb("pm list packages -d")[1])
    return off | (package_names(adb("pm list packages -u")[1]) - package_names(adb("pm list packages")[1]))


# {package: apk path} from 'pm list packages -f' output.
def parse_package_paths(text):
    pairs = (line[8:].rsplit("=", 1) for line in text.splitlines() if line.startswith("package:") and "=" in line)
    return {pkg: apk for apk, pkg in pairs}


# Packages that have an icon in the app drawer.
def parse_launcher_packages(text):
    return set(re.findall(r"^\s*([\w.]+)/", text, re.M))


# One menu row: [OFF], [app] (has an icon) or [service] (no icon), then the name.
def package_row(pkg, name, launcher, off):
    tag = "[OFF]" if off else "[app]" if pkg in launcher else "[service]"
    return f"{tag} {name} ({pkg})" if name else f"{tag} {pkg}"


TIER_HEADERS = {1: "YOUR APPS - safe", 2: "PREINSTALLED EXTRAS - safe",
                3: "SYSTEM PARTS - possible, NOT recommended", 4: "CRITICAL SYSTEM - switched off, turn back on"}


def parse_tiers(text):
    """{package: (tier, name)} from lines of "<tier> <package> <name>"."""
    rows = (line.split(None, 2) for line in text.splitlines())
    return {r[1]: (int(r[0]), r[2]) for r in rows if len(r) == 3 and r[0] in ("2", "3")}


def load_tiers():
    # One shared table for optimize and cleanup, kept in the appops part of this file.
    # Started through bash so it also works on Windows, where a .sh file cannot be run directly.
    r = subprocess.run([shutil.which("bash") or "bash", os.environ["PHONE_SELF"], "_appops", "tiers"],
                       capture_output=True, text=True)
    return parse_tiers(r.stdout)


# 1 = your app, 2 = safe extra, 3 = not recommended, 4 = critical (hidden).
def package_tier(p, user, tiers):
    return 1 if p in user else tiers.get(p, (4, ""))[0]


def package_name(p, labels, tiers):
    label = labels.get(p) or ""
    # "[Ðîĝîţåļ ... one two]" is Android's pseudo-locale test text, not a real name
    return (label if not label.startswith("[") else "") or tiers.get(p, (0, ""))[1]


def disable_entries(apks, labels, launcher, off, user, tiers):
    """Menu rows as (text, package), grouped by tier with a header row (package None) above each group.
    Tier 4 is every preinstalled package missing from the table: hidden unless it is off."""
    def tier(p):
        return package_tier(p, user, tiers)

    def name(p):
        return package_name(p, labels, tiers)

    entries, last = [], None
    for p in sorted(apks, key=lambda p: (tier(p), (name(p) or p).casefold())):
        if tier(p) == 4 and p not in off:
            continue
        if tier(p) != last:
            last = tier(p)
            entries.append((f"----- {TIER_HEADERS[last]} -----", None))
        entries.append((package_row(p, name(p), launcher, p in off), p))
    return entries


# The first useful line of an error message, for short FAILED reports.
def first_error(out, err):
    lines = [line.strip() for line in (err + out).splitlines() if line.strip() and "Exception occurred" not in line]
    return lines[0][:160] if lines else "no reason given"


def set_packages_off(selected, to_disable, labels):
    """Switch packages off or back on, and report each result from the phone's own list."""
    for p in selected:
        q = shlex.quote(p)
        name = labels.get(p) or p
        if p not in to_disable:
            _, out, err = adb(f"pm enable --user 0 {q}")
            if p in disabled_packages():
                _, out, err = adb(f"cmd package install-existing --user 0 {q}")
            print(f"  FAILED, not enabled: {name}: {first_error(out, err)}" if p in disabled_packages()
                  else f"  enabled: {name}")
            continue
        _, out, err = adb(f"pm disable-user --user 0 {q}")
        if p in disabled_packages():
            print(f"  disabled: {name}")
            continue
        # Some phones refuse disabling certain packages but still allow removing them for this user.
        refusal = first_error(out, err)
        _, out, err = adb(f"pm uninstall -k --user 0 {q}")
        if p in disabled_packages():
            print(f"  removed for this user (disable was refused): {name}")
        else:
            print(f"  FAILED: {name}\n    disable: {refusal}\n    remove: {first_error(out, err)}")


# Guards typed package names: only letters, digits, _ and dots, so nothing else reaches the shell.
def valid_package_name(name):
    return re.fullmatch(r"[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*", name) is not None


# CUSTOM row: switch any package off or on by typing its name.
def disable_custom(labels):
    name = ask("Package name, such as com.miui.analytics (empty cancels): ")
    if not name:
        return
    if not valid_package_name(name):
        print("That is not a valid package name.")
        return
    installed = parse_package_paths(adb("pm list packages -f -u")[1])
    if name not in installed:
        close = sorted(p for p in installed if name.lower() in p.lower())
        print(f"{name} is not installed." + (" Close matches:" if close else ""))
        for p in close[:15]:
            print(f"  {p}")
        if len(close) > 15:
            print(f"  ...and {len(close) - 15} more")
        return
    if name in disabled_packages():
        if ask(f"{name} is off. Enable it again? [y/N] ").lower() == "y":
            set_packages_off([name], [], labels)
        else:
            print("Cancelled.")
        return
    if ask(f"Disable {labels.get(name) or name}? [y/N] ").lower() == "y":
        set_packages_off([name], [name], labels)
    else:
        print("Cancelled.")


# Menu: switch apps and background services off or back on.
def full_uninstall(q):
    """The most complete uninstall Android allows without root, for one quoted package:
    "pm uninstall" removes an app you installed entirely, or deletes a preinstalled app's updates from storage;
    the loop then removes it, with its data, for every user and profile on the phone.
    What is left of a preinstalled app is only its factory file in the read-only system image."""
    return (f"pm uninstall {q}; for u in $(pm list users | grep -o 'UserInfo{{[0-9]*' | grep -o '[0-9]*$'); "
            f"do pm uninstall --user $u {q}; done")


def uninstall_menu():
    """Uninstall anything, system parts included. Unsafe ones are marked and need a second, typed confirmation."""
    print("Apps you installed are uninstalled completely. For preinstalled ones the updates are deleted and they are")
    print("removed for every user with all their data. Only the factory file stays in the read-only system image:")
    print("deleting that needs root.")
    print("Bring one back with 'Disable apps & services' > ENABLE ALL or CUSTOM. A factory reset brings all back.")
    apks = parse_package_paths(adb("pm list packages -f")[1])
    labels, tiers = load_labels(apks), load_tiers()
    while True:
        user, installed = user_packages(), package_names(adb("pm list packages")[1])

        def unsafe(p):
            return package_tier(p, user, tiers) >= 3 or bool(PROTECTED_APPS.search(p))

        def name(p):
            return package_name(p, labels, tiers) or p

        order = sorted(installed, key=lambda p: (package_tier(p, user, tiers), name(p).casefold()))
        rows = [f"{'[UNSAFE] ' if unsafe(p) else ''}{name(p)} ({p})" for p in order]
        chosen = pick("Uninstall", rows, "Your apps first, system parts last | Enter = uninstall | Tab = select several | Esc = back",
                      multi=True)
        if not chosen:
            return
        selected = [order[i] for i in chosen]
        risky = [p for p in selected if unsafe(p)]
        for p in selected[:10]:
            print(f"  {'[UNSAFE] ' if p in risky else ''}{name(p)}")
        if len(selected) > 10:
            print(f"  ...and {len(selected) - 10} more")
        if ask(f"Uninstall {len(selected)}? [y/N] ").lower() != "y":
            print("Cancelled.")
            continue
        if risky:
            print(f"UNSAFE: {len(risky)} of them belong to Android, Google or the phone maker. Removing them can break calls,")
            print("the lock screen, notifications, the Play Store or this USB connection. If the phone breaks, only a")
            print("factory reset brings them back, and that erases your data.")
            if ask("Type REMOVE to uninstall them anyway: ") != "REMOVE":
                print("Cancelled.")
                continue
        for p in selected:
            q = shlex.quote(p)
            _, out, err = adb(f"pm uninstall {q}" if p in user else full_uninstall(q))
            gone = p not in package_names(adb("pm list packages")[1])
            if not gone and p not in user:   # the phone refused: disable it instead
                adb(f"pm disable-user --user 0 {q}")
                if p in package_names(adb("pm list packages -d")[1]):
                    print(f"  the phone refused to uninstall {name(p)}, so it is disabled instead.")
                    continue
            print(f"  uninstalled: {name(p)}" if gone else f"  FAILED: {name(p)}: {first_error(out, err)}")
            if not gone and "DEVICE_POLICY_MANAGER" in out + err:
                print("    It is a device admin app (Google Play Services is one, for Find My Device). On the phone:")
                print("    Settings > Security > Device admin apps, switch it off there, then uninstall it again.")


def disable_menu():
    print("Loading apps and services...")
    apks = parse_package_paths(adb("pm list packages -f -u")[1])
    if not apks:
        print("Could not read the app list.")
        return
    labels = load_labels(apks)
    _, out, _ = adb("cmd package query-activities --brief -a android.intent.action.MAIN "
                    "-c android.intent.category.LAUNCHER")
    launcher = parse_launcher_packages(out)
    print("Services are background packages with no icon: Android blocks disabling parts of a package over USB.")
    print("Order: your apps, safe preinstalled extras, then system parts that are not recommended.")
    print("Critical system packages are hidden. CUSTOM still reaches them by package name.")
    user = user_packages("-u")
    tiers = load_tiers()
    if not tiers:
        print("Could not load the app groups, so only your own apps are listed.")
    while True:
        off = disabled_packages()
        entries = disable_entries(apks, labels, launcher, off, user, tiers)
        rows = [text for text, _ in entries]
        packages = [p for _, p in entries if p]
        chosen = pick("Disable", ["[ CUSTOM: type a package name ]", f"[ DISABLE ALL {len(packages)} ]",
                                  f"[ ENABLE ALL {len(off)} ]"] + rows,
                      "Enter = disable, or enable if [OFF] | Tab = select several | Esc = back", multi=True)
        if not chosen:
            return
        if 0 in chosen:
            disable_custom(labels)
            continue
        if 1 in chosen:
            print(f"This turns off all {len(packages)} listed packages, including settings, Play services and the keyboard.")
            print("Hidden critical packages stay on, but the phone will be barely usable until you enable them again.")
            if ask("Type DISABLE ALL to confirm: ") == "DISABLE ALL":
                remaining = [p for p in packages if p not in off]
                set_packages_off(remaining, remaining, labels)
            else:
                print("Cancelled.")
            continue
        if 2 in chosen:
            # Critical packages go first so the phone recovers even if the connection drops midway.
            set_packages_off(sorted(off, key=lambda p: not PROTECTED_APPS.search(p)), [], labels)
            continue
        selected = [entries[i - 3][1] for i in chosen if entries[i - 3][1]]  # header rows carry no package
        if not selected:
            continue
        to_disable = [p for p in selected if p not in off]
        if to_disable:
            for p in to_disable[:5]:
                print(f"  {labels[p] or p}")
            if ask(f"Disable {len(to_disable)}? [y/N] ").lower() != "y":
                print("Cancelled.")
                continue
        set_packages_off(selected, to_disable, labels)


# --- permissions ---

# Most important and most common first. (title, permission names, special access as (app-op, mode that
# switches it off) or None). Special access is what Settings lists under "Special app access".
PERMISSIONS = [
    ("Location", "ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION", None),
    ("Camera", "CAMERA", None),
    ("Microphone", "RECORD_AUDIO", None),
    ("Notifications", "POST_NOTIFICATIONS", None),
    ("Photos and videos", "READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_VISUAL_USER_SELECTED", None),
    ("Contacts", "READ_CONTACTS WRITE_CONTACTS GET_ACCOUNTS", None),
    ("Phone", "READ_PHONE_STATE CALL_PHONE READ_PHONE_NUMBERS ANSWER_PHONE_CALLS", None),
    ("SMS", "SEND_SMS RECEIVE_SMS READ_SMS RECEIVE_MMS RECEIVE_WAP_PUSH", None),
    ("Call logs", "READ_CALL_LOG WRITE_CALL_LOG", None),
    ("All files access", "MANAGE_EXTERNAL_STORAGE", ("MANAGE_EXTERNAL_STORAGE", "deny")),
    ("Files (old storage permission)", "READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE", None),
    ("Music and audio", "READ_MEDIA_AUDIO", None),
    ("Nearby devices", "BLUETOOTH_CONNECT BLUETOOTH_SCAN BLUETOOTH_ADVERTISE NEARBY_WIFI_DEVICES UWB_RANGING", None),
    ("Location in the background", "ACCESS_BACKGROUND_LOCATION", None),
    ("Calendar", "READ_CALENDAR WRITE_CALENDAR", None),
    ("Usage access", "PACKAGE_USAGE_STATS", ("GET_USAGE_STATS", "ignore")),
    ("Display over other apps", "SYSTEM_ALERT_WINDOW", ("SYSTEM_ALERT_WINDOW", "deny")),
    ("Install unknown apps", "REQUEST_INSTALL_PACKAGES", ("REQUEST_INSTALL_PACKAGES", "deny")),
    ("Modify system settings", "WRITE_SETTINGS", ("WRITE_SETTINGS", "deny")),
    ("Physical activity", "ACTIVITY_RECOGNITION", None),
    ("Body sensors", "BODY_SENSORS BODY_SENSORS_BACKGROUND", None),
]
GREEN = "\033[32m{}\033[0m"


def parse_permissions(dump):
    """{package: (requested, granted)} from "dumpsys package packages". Runtime grants count for user 0 only."""
    packages, pkg, section, user = {}, None, None, None
    for line in dump.splitlines():
        m = re.match(r"  Package \[([\w.]+)\]", line)
        if m:
            pkg, section, user = m.group(1), None, None
            packages[pkg] = (set(), set())
            continue
        text = line.strip()
        if pkg is None or not text:
            continue
        m = re.match(r"User (\d+):", text)
        if m:
            user, section = m.group(1), None
        elif text in ("requested permissions:", "install permissions:", "runtime permissions:"):
            section = text.split()[0]
        else:
            m = re.fullmatch(r"([\w.]+)(?:: (.*))?", text) if section else None
            if not m:
                section = None
            else:
                # Some phones leave "requested permissions" out of this dump; a grant entry implies a request.
                packages[pkg][0].add(m.group(1))
                if (m.group(2) or "").startswith("granted=true") and (section == "install" or user == "0"):
                    packages[pkg][1].add(m.group(1))
    return packages


def parse_op_modes(text):
    """{app-op: {package: mode}} from blocks headed "#OP mode"."""
    modes, op, mode = {}, None, None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#"):
            op, mode = line[1:].split()
        elif op and valid_package_name(line) and "." in line:
            modes.setdefault(op, {})[line] = mode
    return modes


def parse_special_requests(text):
    """{package: [permissions]} from lines of "#package permission permission..."."""
    return {words[0][1:]: words[1:] for words in map(str.split, text.splitlines()) if words and words[0][0] == "#"}


def load_special_requests(apks):
    """Which special-access permissions each package asks for. An app that asks but was never allowed shows
    up only in its own dump, which is slow to read for every app, so results are cached per APK path."""
    try:
        with open(PERMISSION_CACHE) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    missing = [p for p, apk in apks.items() if cache.get(p, {}).get("apk") != apk]
    wanted = "|".join(names for _, names, special in PERMISSIONS if special)
    for start in range(0, len(missing), 100):
        batch = missing[start:start + 100]
        print(f"\rReading special access {start + len(batch)}/{len(missing)} (first run is the slowest)   ",
              end="", flush=True)
        _, out, _ = adb(f"i=0; for p in {' '.join(map(shlex.quote, batch))}; do "
                        f"{{ echo \"#$p\" $(dumpsys package $p | grep -oE 'android.permission.({wanted})$'); }} & "
                        "i=$((i+1)); [ $((i%8)) = 0 ] && wait; done; wait")
        found = parse_special_requests(out)
        for p in batch:
            if p in found:  # a package missing from the answer is retried next time
                cache[p] = {"apk": apks[p], "requests": found[p]}
    if missing:
        print()
        with open(PERMISSION_CACHE, "w") as f:
            json.dump(cache, f)
    return {p: set(cache[p]["requests"]) for p in apks if p in cache}


def load_permission_state(requests):
    ops = " ".join(special[0] for _, _, special in PERMISSIONS if special)
    _, out, _ = adb(f'for op in {ops}; do for m in allow deny ignore; do echo "#$op $m"; '
                    'cmd appops query-op $op $m; done; done')
    packages = parse_permissions(adb("dumpsys package packages")[1])
    for pkg, extra in requests.items():
        if pkg in packages:
            packages[pkg][0].update(extra)
    return packages, parse_op_modes(out)


def permission_holders(names, special, packages, modes):
    """{package: has it} for every package that requests one of the permissions."""
    full = {"android.permission." + n for n in names.split()}
    state = {}
    for pkg, (requested, granted) in packages.items():
        if not requested & full:
            continue
        # shortcut: an app-op left on "default" follows the granted permission, which holds for these five
        # special accesses; other app-ops have per-version defaults and would need their own rule.
        mode = modes.get(special[0], {}).get(pkg) if special else None
        state[pkg] = mode == "allow" if mode else bool(granted & full)
    return state


# Give or take away one permission group from one app.
def set_permission(pkg, names, special, on, requested):
    q = shlex.quote(pkg)
    if special:
        return adb(f"cmd appops set {q} {special[0]} {'allow' if on else special[1]}")
    wanted = [n for n in names.split() if "android.permission." + n in requested]
    return adb("; ".join(f"pm {'grant' if on else 'revoke'} {q} android.permission.{n}" for n in wanted))


# Second level of the permissions menu: the apps for one permission.
def permission_apps_menu(title, names, special, visible, tier, name, requests):
    while True:
        packages, modes = load_permission_state(requests)
        state = {p: has for p, has in permission_holders(names, special, packages, modes).items() if p in visible}
        if not state:
            print(f"No listed app asks for {title}.")
            return
        entries, last = [], None
        for p in sorted(state, key=lambda p: (not state[p], tier(p), (name(p) or p).casefold())):
            if state[p] != last:
                last = state[p]
                entries.append(("----- HAVE IT -----" if last else "----- DO NOT HAVE IT, BUT CAN -----", None))
            text = ("[system part] " if tier(p) == 3 else "") + (f"{name(p)} ({p})" if name(p) else p)
            entries.append((GREEN.format(text) if last else text, p))
        chosen = pick(title, [text for text, _ in entries],
                      "Green = has it | Enter = take away, or give if not green | Tab = select several | Esc = back",
                      multi=True, ansi=True)
        if not chosen:
            return
        selected = [entries[i][1] for i in chosen if entries[i][1]]
        errors = {p: first_error(*set_permission(p, names, special, not state[p], packages[p][0])[1:])
                  for p in selected}
        after = permission_holders(names, special, *load_permission_state(requests))
        for p in selected:
            label = name(p) or p
            if after.get(p) == state[p]:
                print(f"  FAILED, unchanged: {label}: {errors[p]}")
            else:
                print(f"  {'given' if after.get(p) else 'taken away'}: {label}")


# First level of the permissions menu: one row per permission with counts.
def permissions_menu():
    print("Loading permissions...")
    apks = parse_package_paths(adb("pm list packages -f")[1])
    if not apks:
        print("Could not read the app list.")
        return
    labels = load_labels(apks)
    user = user_packages()
    tiers = load_tiers()

    def tier(p):
        return package_tier(p, user, tiers)

    def name(p):
        return package_name(p, labels, tiers)

    # Same rule as optimize: critical system packages are never listed.
    visible = {p for p in apks if tier(p) < 4}
    requests = load_special_requests({p: apks[p] for p in visible})
    while True:
        packages, modes = load_permission_state(requests)
        rows = []
        for title, names, special in PERMISSIONS:
            state = [has for p, has in permission_holders(names, special, packages, modes).items() if p in visible]
            rows.append(f"{title:<32}{sum(state):>3} have it, {len(state) - sum(state):>3} can")
        chosen = pick("Permissions", rows, "Most important first | Enter = open | Esc = quit")
        if not chosen:
            return
        title, names, special = PERMISSIONS[chosen[0]]
        permission_apps_menu(title, names, special, visible, tier, name, requests)


# --- notifications ---

NOTIFICATION_PERMISSION = "android.permission.POST_NOTIFICATIONS"
SHELL_BATCH = 40


# Packages whose notifications are blocked, from 'cmd appops get' output.
def parse_notifications_off(text):
    off, current = set(), None
    for line in text.splitlines():
        if line.startswith("="):
            current = line[1:].strip()
        elif current and re.search(r"POST_NOTIFICATION: (ignore|deny)", line):
            off.add(current)
    return off


def in_batches(packages, command_for):
    """Run a command per package, sharing connections because 300 separate ones are slow."""
    batches = [packages[i:i + SHELL_BATCH] for i in range(0, len(packages), SHELL_BATCH)]
    with ThreadPoolExecutor(4) as pool:
        return "\n".join(pool.map(lambda batch: adb("; ".join(command_for(shlex.quote(p)) for p in batch))[1], batches))


# Ask the phone which of these packages have notifications blocked.
def notifications_off(packages):
    return parse_notifications_off(in_batches(
        packages, lambda q: f"echo ={q}; cmd appops get {q} POST_NOTIFICATION"))


def set_notifications(selected, turn_off):
    """Block or allow by permission and app op, then return what did not change."""
    # Apps built for older Android have no such permission, so only the app op applies and pm errors are ignored.
    if turn_off:
        command = lambda q: (f"pm revoke --user 0 {q} {NOTIFICATION_PERMISSION} >/dev/null 2>&1; "
                             f"cmd appops set {q} POST_NOTIFICATION ignore")
    else:
        command = lambda q: (f"pm grant --user 0 {q} {NOTIFICATION_PERMISSION} >/dev/null 2>&1; "
                             f"cmd appops set {q} POST_NOTIFICATION allow")
    in_batches(selected, command)
    now_off = notifications_off(selected)
    return [p for p in selected if (p in now_off) != turn_off]


# Menu: turn notifications off or on per app, or for all apps.
def notifications_menu():
    print("Loading notification settings...")
    apks = parse_package_paths(adb("pm list packages -f")[1])
    if not apks:
        print("Could not read the app list.")
        return
    labels = load_labels(apks)
    packages = sorted(apks, key=lambda p: (labels[p] or p).casefold())
    off = notifications_off(packages)
    while True:
        rows = [("[OFF] " if p in off else "") + (f"{labels[p]} ({p})" if labels[p] else p) for p in packages]
        chosen = pick("Notifications", [f"[ DISABLE ALL {len(packages) - len(off)} ]", f"[ ENABLE ALL {len(off)} ]"] + rows,
                      "Enter = off, or on if [OFF] | Tab = select several | Esc = back", multi=True)
        if not chosen:
            return
        if 0 in chosen:
            print("Incoming call screens and alarms can stop showing while notifications are off for their apps.")
            if ask("Type DISABLE ALL to confirm: ") != "DISABLE ALL":
                print("Cancelled.")
                continue
            turn_off, turn_on = [p for p in packages if p not in off], []
        elif 1 in chosen:
            turn_off, turn_on = [], sorted(off)
        else:
            selected = [packages[i - 2] for i in chosen]
            turn_off, turn_on = [p for p in selected if p not in off], [p for p in selected if p in off]
        failed = (set_notifications(turn_off, True) if turn_off else []) + (
            set_notifications(turn_on, False) if turn_on else [])
        off = notifications_off(packages)
        print(f"Turned off {len(turn_off)} and on {len(turn_on)}, {len(failed)} failed.")
        for p in failed[:10]:
            print(f"  FAILED: {labels[p] or p}")
        if len(failed) > 10:
            print(f"  ...and {len(failed) - 10} more")


# --- free RAM ---

# Free RAM in MB from /proc/meminfo.
def parse_available_mb(meminfo):
    m = re.search(r"^MemAvailable:\s+(\d+) kB", meminfo, re.M)
    return int(m[1]) // 1024 if m else None


def parse_foreground_packages(text):
    """Packages with a foreground service, such as music, navigation or a VPN."""
    found, current = set(), None
    for line in text.splitlines():
        record = re.search(r"ServiceRecord\{\S+ u\d+ ([\w.]+)/", line)
        if record:
            current = record[1]
        elif "isForeground=true" in line and current:
            found.add(current)
    return found


# Package names of running processes ("com.app:service" counts as com.app).
def parse_running_packages(ps_output):
    return {line.strip().split(":")[0] for line in ps_output.splitlines() if "." in line}


def packages_to_keep():
    """Whatever the user would notice losing: home, keyboard, calls, SMS, and foreground services."""
    return essential_packages() | parse_foreground_packages(adb("dumpsys activity services")[1])


def essential_packages():
    """Home screen, keyboard, calls, SMS, assistant, accessibility, notification listeners and VPN."""
    text = adb("cmd package resolve-activity --brief -c android.intent.category.HOME "
               "-a android.intent.action.MAIN")[1]
    for role in ("SMS", "DIALER", "HOME", "ASSISTANT"):
        text += "\n" + adb(f"cmd role get-role-holders android.app.role.{role}")[1].replace(";", "\n")
    for key in ("default_input_method", "enabled_accessibility_services",
                "enabled_notification_listeners", "always_on_vpn_app"):
        text += "\n" + adb(f"settings get secure {key}")[1].replace(":", "\n")
    return {re.split(r"[/\s]", line.strip())[0] for line in text.splitlines() if "." in line}


# Free RAM on the phone right now.
def available_mb():
    return parse_available_mb(adb("cat /proc/meminfo")[1])


# Apps the user never wants closed by 'Hard' close, saved on this computer.
def load_exceptions():
    try:
        with open(EXCEPTIONS_FILE) as f:
            return set(json.load(f))
    except (OSError, ValueError, TypeError):
        return set()


def save_exceptions(exceptions):
    os.makedirs(os.path.dirname(EXCEPTIONS_FILE), exist_ok=True)
    with open(EXCEPTIONS_FILE, "w") as f:
        json.dump(sorted(exceptions), f)


def choose_exceptions():
    """Let the user mark apps to keep. Returns the saved set, or None if they press Esc."""
    # Preinstalled apps with an icon count too: they also get closed, and users think of them as apps.
    apps_with_icon = parse_launcher_packages(adb("cmd package query-activities --brief -a android.intent.action.MAIN "
                                                 "-c android.intent.category.LAUNCHER")[1])
    choices = user_packages() | apps_with_icon
    apks = {p: apk for p, apk in parse_package_paths(adb("pm list packages -f")[1]).items() if p in choices}
    labels = load_labels(apks)
    exceptions = load_exceptions()
    while True:
        apps = sorted(apks, key=lambda p: (p not in exceptions, (labels[p] or p).casefold()))
        rows = [("[KEEP] " if p in exceptions else "") + (f"{labels[p]} ({p})" if labels[p] else p) for p in apps]
        kept = len(exceptions & apks.keys())
        chosen = pick("Hard exceptions", [f"[ RUN HARD CLOSE, keeping {kept} ]"] + rows,
                      "Enter = KEEP on or off | Tab = select several | Top row = run | Esc = back", multi=True)
        if not chosen:
            return None
        if 0 in chosen:
            return exceptions
        exceptions ^= {apps[i - 1] for i in chosen}
        save_exceptions(exceptions)


# Menu: close background apps to free RAM, keeping the ones you would notice.
def close_apps_menu():
    modes = ["Normal: closes background apps and services, notifications keep working",
             "Hard: force-stops your apps too, they get no notifications or alarms until reopened"]
    chosen = pick("Free RAM", modes, "Enter = run | Esc = back")
    if not chosen:
        return
    hard = chosen[0] == 1
    exceptions = choose_exceptions() if hard else load_exceptions()
    if exceptions is None:
        return
    before = available_mb()
    running = parse_running_packages(adb("ps -A -o NAME")[1])
    third_party = user_packages()
    keep = packages_to_keep() | exceptions
    # System processes only get am kill: Android refuses it for essential ones, and they restart if needed.
    targets = sorted(p for p in running if p not in keep and not PROTECTED_APPS.search(p))
    stop = [p for p in targets if hard and p in third_party]
    commands = [f"am force-stop {shlex.quote(p)}" for p in stop]
    commands += [f"am kill {shlex.quote(p)}" for p in targets if p not in stop]
    for start in range(0, len(commands), 50):
        adb("; ".join(commands[start:start + 50]))
    adb("am kill-all")
    time.sleep(3)  # let freed memory show up in the kernel's count
    after = available_mb()
    print(f"Closed {len(stop)} apps and asked {len(targets) - len(stop)} background processes to exit. "
          f"Kept {len(running & keep)} that you would notice.")
    if before is not None and after is not None:
        print(f"Available RAM: {before} MB -> {after} MB ({after - before:+} MB)")
    print("Android restarts some services by itself, so a bit of this RAM gets used again.")


# --- settings ---

# Which settings group a key belongs to.
def setting_category(key):
    for name, pattern in SETTING_CATEGORIES.items():
        if re.search(pattern, key, re.I):
            return name
    return SETTINGS_OTHER


# (key, value) pairs from 'settings list' output.
def parse_settings(text):
    return re.findall(r"^([\w.\-]+)=(.*)$", text, re.M)


def parse_wifi_networks(text):
    # One network can span several rows with the same id, one per security type.
    return list(dict(re.findall(r"^(\d+)[ \t]+(.*?)[ \t]+\S+[ \t]*$", text, re.M)).items())


# Saved Wi-Fi networks, shown as deletable rows in Settings > Wi-Fi.
def load_wifi_networks():
    _, out, _ = adb("cmd wifi list-networks")
    return [(("wifi", net_id), f"Saved network: {ssid}") for net_id, ssid in parse_wifi_networks(out)]


# All settings of one group, minus the protected ones.
def load_settings(category):
    items = load_wifi_networks() if category == "Wi-Fi" else []
    for namespace in ("system", "secure", "global"):
        _, out, _ = adb(f"settings list {namespace}")
        for key, value in parse_settings(out):
            if not PROTECTED_SETTINGS.search(key) and setting_category(key) == category:
                items.append(((namespace, key), f"{namespace}/{key} = {value[:40]}"))
    return items


# Reset one setting to its default (or forget a Wi-Fi network). Returns True if it worked.
def delete_setting(item):
    namespace, key = item
    if namespace == "wifi":
        adb(f"cmd wifi forget-network {shlex.quote(key)}")
        _, out, _ = adb("cmd wifi list-networks")
        return key not in [net_id for net_id, _ in parse_wifi_networks(out)]
    q = shlex.quote(key)
    adb(f"settings delete {namespace} {q}")
    _, out, _ = adb(f"settings get {namespace} {q}")
    return out.strip() == "null"


# --- menus ---

# Delete items with a live counter, then list what failed. Returns the failed items.
def delete_items(items, delete, delete_many=None):
    done = 0
    lock = threading.Lock()

    def progress(count=1):
        nonlocal done
        with lock:
            done += count
            print(f"\r[{done}/{len(items)}] deleting...", end="", flush=True)

    if delete_many:
        bad = set(delete_many([item for item, _ in items], progress))
    else:
        bad = set()
        for item, _ in items:
            if not delete(item):
                bad.add(item)
            progress()
    failed = [entry for entry in items if entry[0] in bad]
    print(f"\rDeleted {len(items) - len(failed)} of {len(items)}.          ")
    for _, label in failed[:10]:
        print(f"  FAILED: {label}")
    if len(failed) > 10:
        print(f"  ...and {len(failed) - 10} more failed")
    return failed


# Generic 'list, pick, confirm, delete' screen used by most cleanup categories.
def browse(title, load, delete, note="", allow_all=True, delete_many=None):
    if note:
        print(note)
    print(f"Loading {title}...")
    try:
        items = load()
    except PhoneError as e:
        print(f"Could not read {title}: {e}")
        return
    while items:
        top = [f"[ DELETE ALL {len(items)} ]"] if allow_all else []
        chosen = pick(title, top + [label for _, label in items],
                      "Enter = delete | Tab = select several | Esc = back", multi=True)
        if not chosen:
            return
        if allow_all and 0 in chosen:
            print(f"This permanently deletes all {len(items)} items in {title}.")
            if ask("Type DELETE to confirm: ") != "DELETE":
                print("Cancelled.")
                continue
            selected = items
        else:
            selected = [items[i - len(top)] for i in chosen]
            for _, label in selected[:5]:
                print(f"  {label}")
            if len(selected) > 5:
                print(f"  ...and {len(selected) - 5} more")
            if ask(f"Permanently delete {len(selected)}? [y/N] ").lower() != "y":
                print("Cancelled.")
                continue
        failed = delete_items(selected, delete, delete_many)
        gone = {item for item, _ in selected} - {item for item, _ in failed}
        items = [entry for entry in items if entry[0] not in gone]
    print(f"Nothing left in {title}.")


# Menu: pick a settings group, then reset settings in it.
def settings_menu():
    names = list(SETTING_CATEGORIES) + [SETTINGS_OTHER]
    while True:
        chosen = pick("Settings", names, "Enter = open | Esc = back")
        if not chosen:
            return
        name = names[chosen[0]]
        note = "Deleting a setting resets it to its default."
        if name == "Bluetooth":
            note += "\nPaired devices cannot be removed over USB debugging: unpair them on the phone."
        browse(f"Settings > {name}", lambda: load_settings(name), delete_setting, note, name != SETTINGS_OTHER)


# --- backup and restore: one .zip per app, the same format the website uses ---
# The app (every split APK), its shared-storage data (Android/data, Android/obb) and optionally Android's own backup of
# its private data. Apps can opt out of that, and logins tied to the phone's key store never move without root.

BACKUP_DIR = os.path.expanduser("~/phone-backups")


def safe_backup_path(path, package):
    """Backups may only put files back into the app's own Android/data and Android/obb folders."""
    return re.fullmatch(rf"Android/(data|obb)/{re.escape(package)}/[^\0]+", path or "") is not None and ".." not in path.split("/")


def stream_to_zip(zf, name, command):
    """Copy the output of a phone command into the zip without holding it in memory. Returns the size."""
    proc = subprocess.Popen(["adb", "exec-out", command], stdout=subprocess.PIPE)
    size = 0
    with zf.open(name, "w", force_zip64=True) as f:
        while chunk := proc.stdout.read(1 << 20):
            f.write(chunk)
            size += len(chunk)
            print(f"\r  {name}: {fmt_size(size)}   ", end="", flush=True)
    if proc.wait() != 0:
        raise PhoneError(f"copying {name} from the phone failed")
    print()
    return size


def backup_app(package, label, path, android_backup):
    q = shlex.quote(package)
    apks = [line[8:].strip() for line in adb(f"pm path {q}")[1].splitlines() if line.startswith("package:")]
    if not apks:
        raise PhoneError("not installed")
    out = adb(f"find {shlex.quote('/sdcard/Android/data/' + package)} {shlex.quote('/sdcard/Android/obb/' + package)} "
              "-type f -exec stat -c '%s %n' {} + 2>/dev/null")[1]
    files = [(int(size), name) for size, _, name in (line.partition(" ") for line in out.splitlines()) if size.isdigit()]
    version = re.search(r"versionName=(.*)", adb(f"dumpsys package {q} | grep -m1 versionName")[1])
    info = {"format": 1, "package": package, "name": label, "version": version[1].strip() if version else "",
            "phone": adb("getprop ro.product.model")[1].strip(), "created": datetime.now().isoformat(timespec="seconds"),
            "apks": [], "files": [], "androidBackup": 0}
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
        for i, apk in enumerate(apks):
            name = f"apk/{'base' if i == 0 else f'split{i}'}-{os.path.basename(apk)}"
            stream_to_zip(zf, name, f"cat {shlex.quote(apk)}")
            info["apks"].append(name)
        for size, name in files:
            rel = name[len("/sdcard/"):]
            stream_to_zip(zf, "files/" + rel, f"cat {shlex.quote(name)}")
            info["files"].append({"path": rel, "size": size})
        if android_backup:
            print("  Confirm the backup on the phone.")
            info["androidBackup"] = stream_to_zip(zf, "android-backup.ab", f"bu backup -noapk -noobb -noshared {q}")
        zf.writestr("backup.json", json.dumps(info, indent=1))
    return info


def backup_menu():
    apps = load_apps()
    chosen = pick("Back up", [label for _, label in apps], "Enter = back up | Tab = select several | Esc = back", multi=True)
    if not chosen:
        return
    android_backup = ask("Also Android's own backup of private data? You confirm it on the phone; many apps opt out "
                         "and logins usually do not transfer. [y/N] ").lower() == "y"
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d-%H-%M")
    for i in chosen:
        package, label = apps[i][0], apps[i][1][10:].rsplit(" (", 1)[0]
        path = os.path.join(BACKUP_DIR, f"{package}-{stamp}.zip")
        print(f"Backing up {label}...")
        try:
            info = backup_app(package, label, path, android_backup)
            print(f"  saved {path}: {len(info['apks'])} app part(s), {len(info['files'])} data files"
                  + (f", Android backup {fmt_size(info['androidBackup'])}" + (" (empty: the app does not allow it)" if info["androidBackup"] < 1024 else "")
                     if android_backup else ""))
        except (OSError, PhoneError, subprocess.SubprocessError) as e:
            print(f"  FAILED: {label}: {e}")
            if os.path.exists(path):
                os.remove(path)   # only the half-written backup this run just created


def restore_backup(path):
    with zipfile.ZipFile(path) as zf, tempfile.TemporaryDirectory() as tmp:
        info = json.loads(zf.read("backup.json"))
        package = info.get("package", "")
        bad = [f["path"] for f in info.get("files", []) if not safe_backup_path(f.get("path"), package)]
        if not valid_package_name(package) or bad:
            raise PhoneError("this backup wants to write outside the app's own folders, so it is not restored")
        apks = [zf.extract(name, tmp) for name in info["apks"]]
        r = subprocess.run(["adb", "install", "-r", apks[0]] if len(apks) == 1 else ["adb", "install-multiple", "-r", *apks],
                           capture_output=True, text=True, errors="replace")
        if "Success" not in r.stdout + r.stderr:
            raise PhoneError((r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "install failed")
        for f in info["files"]:
            local, remote = zf.extract("files/" + f["path"], tmp), "/sdcard/" + f["path"]
            adb(f"mkdir -p {shlex.quote(os.path.dirname(remote))}")
            if subprocess.run(["adb", "push", local, remote], capture_output=True).returncode != 0:
                raise PhoneError(f"could not copy {f['path']} back to the phone")
            os.remove(local)   # a temp copy, so big game data does not pile up on this computer
        if info.get("androidBackup", 0) > 1024:
            print("  Confirm the restore on the phone.")
            subprocess.run(["adb", "restore", zf.extract("android-backup.ab", tmp)])
    return info


def restore_menu():
    zips = sorted((f for f in os.listdir(BACKUP_DIR) if f.endswith(".zip")), reverse=True) if os.path.isdir(BACKUP_DIR) else []
    if not zips:
        print(f"No backups in {BACKUP_DIR}. Backups from the website can be copied there too.")
        return
    chosen = pick("Restore", zips, "Enter = restore | Tab = select several | Esc = back", multi=True)
    if not chosen or ask("Restore? This replaces the app and its data on the phone. [y/N] ").lower() != "y":
        return
    for i in chosen:
        print(f"Restoring {zips[i]}...")
        try:
            info = restore_backup(os.path.join(BACKUP_DIR, zips[i]))
            print(f"  restored: {info.get('name') or info['package']} {info.get('version', '')}")
        except (OSError, PhoneError, ValueError, KeyError, zipfile.BadZipFile) as e:
            print(f"  FAILED: {zips[i]}: {e}")


# Top-level Cleanup menu.
def main_menu():
    names = list(FILE_CATEGORIES) + list(CONTENT_CATEGORIES) + ["Back up apps", "Restore backups"] + [
        "Apps", "App data", "System app data (no delete all)", "Settings", "Keyboard learned words", "Screen lock & fingerprints",
        "Disable apps & services", "Uninstall anything (unsafe)", "Close apps & free RAM", "Notifications", "Flush free space"]
    while True:
        chosen = pick("Cleanup", names, "Enter = open | Esc = quit")
        if not chosen:
            return
        name = names[chosen[0]]
        if name == "Settings":
            settings_menu()
        elif name == "Back up apps":
            backup_menu()
        elif name == "Restore backups":
            restore_menu()
        elif name == "Apps":
            browse("Apps", load_apps, delete_app)
        elif name == "App data":
            browse(name, load_apps, clear_app_data, "Keeps each app installed but erases its data and sign-ins.")
        elif name.startswith("System app data"):
            browse("System app data", load_system_apps, clear_app_data,
                   "Erases that app's data and sign-ins and resets it. Critical system apps are hidden.", False)
        elif name == "Keyboard learned words":
            browse(name, load_keyboards, clear_app_data,
                   "Erases learned words, predictions and that keyboard's settings. "
                   "Words synced to a cloud account are not touched.")
        elif name == "Screen lock & fingerprints":
            lock_menu()
        elif name.startswith("Uninstall anything"):
            uninstall_menu()
        elif name == "Disable apps & services":
            disable_menu()
        elif name == "Close apps & free RAM":
            close_apps_menu()
        elif name == "Notifications":
            notifications_menu()
        elif name == "Flush free space":
            flush_free_space()
        elif name in FILE_CATEGORIES:
            browse(name, lambda: load_files(FILE_CATEGORIES[name]), None, delete_many=wipe_files)
        else:
            uri, projection, fields, note, live = CONTENT_CATEGORIES[name]
            browse(name, lambda: load_content(uri, projection, fields, live),
                   None, note, delete_many=lambda ids, progress: delete_content_many(uri, ids, live, progress))


# --- battery ---
# Everything here is done once and remembered, so RESTORE can undo it. Nothing kills apps on a timer:
# killed apps restart, and restarting costs more battery than leaving them asleep.

BACKUP_FILE = os.path.expanduser("~/.config/phone-battery-backup.json")
KEEP_FILE = os.path.expanduser("~/.config/phone-keep.json")

# Ticked on the first run when installed. The user decides the final list.
SUGGESTED_KEEP = {"com.whatsapp", "org.thoughtcrime.securesms", "com.discord", "org.telegram.messenger",
                  "com.grupet.web.app"}
# Push messages for every app arrive through these, so they always keep background data.
ALWAYS_KEEP = {"com.google.android.gms", "com.google.android.gsf", "com.sec.spp.push"}

# Used while power saving is on. Samsung may ignore some of these; Android's own ones still apply.
SAVER_CONSTANTS = ",".join([
    "force_all_apps_standby=true", "force_background_check=true", "quick_doze_enabled=true",
    "optional_sensors_disabled=true", "aod_disabled=true", "vibration_disabled=true",
    "launch_boost_disabled=true", "soundtrigger_disabled=true", "fullbackup_deferred=true",
    "keyvaluebackup_deferred=true", "enable_night_mode=true",
])

# (namespace, key, value, Samsung-only: set only if the phone already has it, what it is)
BATTERY_SETTINGS = [
    ("global", "mobile_data_always_on", "0", False, "Mobile data stays on while on Wi-Fi: off"),
    ("global", "wifi_scan_always_enabled", "0", False, "Wi-Fi scanning while Wi-Fi is off: off"),
    ("global", "ble_scan_always_enabled", "0", False, "Bluetooth scanning while Bluetooth is off: off"),
    ("global", "wifi_networks_available_notification_on", "0", False, "Open Wi-Fi network alerts: off"),
    ("global", "cached_apps_freezer", "enabled", False, "Freeze apps in the background (after a restart)"),
    ("global", "adaptive_battery_management_enabled", "1", False, "Adaptive battery: on"),
    ("global", "low_power_sticky", "1", False, "Power saving stays on after a restart"),
    ("global", "low_power_sticky_auto_disable_enabled", "0", False, "Power saving comes back after charging"),
    ("global", "app_auto_restriction_enabled", "1", False, "Android restricts battery-draining apps by itself: on"),
    ("global", "wifi_wakeup_enabled", "0", False, "Turn on Wi-Fi automatically: off"),
    ("global", "wifi_scan_throttle_enabled", "1", False, "Wi-Fi scan throttling: on"),
    ("global", "disable_window_blurs", "1", False, "Background blur: off"),
    ("secure", "doze_enabled", "0", False, "Screen wakes for new notifications: off"),
    ("secure", "doze_pick_up_gesture", "0", False, "Lift to check phone: off"),
    ("secure", "doze_double_tap_gesture", "0", False, "Double tap to check phone: off"),
    ("secure", "adaptive_sleep", "0", False, "Screen attention (camera watches your face): off"),
    ("system", "peak_refresh_rate", "60.0", False, "Refresh rate: 60 Hz"),
    ("system", "screen_brightness_mode", "1", False, "Adaptive brightness: on"),
    ("secure", "adaptive_connectivity_enabled", "1", False, "Adaptive connectivity (4G when 5G is not needed): on"),
    ("secure", "adaptive_charging_enabled", "1", True, "Adaptive charging (longer battery lifespan): on"),
    ("secure", "send_action_app_error", "0", False, "Send app error reports: off"),
    ("system", "samsung_errorlog_agree", "0", True, "Samsung diagnostic data: off"),
    ("global", "wifi_verbose_logging_enabled", "0", False, "Wi-Fi verbose logging: off"),
    ("global", "stay_on_while_plugged_in", "0", False, "Screen stays on while charging: off"),
    ("global", "network_recommendations_enabled", "0", False, "Network recommendations: off"),
    ("secure", "charging_sounds_enabled", "0", False, "Charging sound: off"),
    ("secure", "charging_vibration_enabled", "0", False, "Charging vibration: off"),
    ("secure", "screensaver_activate_on_dock", "0", False, "Screen saver when docked: off"),
    ("secure", "screensaver_activate_on_sleep", "0", False, "Screen saver while charging: off"),
    ("system", "notification_light_pulse", "0", False, "Notification light: off"),
    ("global", "battery_saver_constants", SAVER_CONSTANTS, False, "Stronger power saving mode"),
    ("global", "window_animation_scale", "0.5", False, "Window animations 0.5x"),
    ("global", "transition_animation_scale", "0.5", False, "Transition animations 0.5x"),
    ("global", "animator_duration_scale", "0.5", False, "Animator duration 0.5x"),
    ("secure", "doze_always_on", "0", False, "Always On Display (Android): off"),
    ("secure", "aod_mode", "0", True, "Always On Display (Samsung): off"),
    ("secure", "aod_tap_to_show_mode", "0", True, "Tap to show AOD: off"),
    ("secure", "doze_pulse_on_pick_up", "0", False, "Screen lights up when picked up: off"),
    ("secure", "doze_tap_gesture", "0", False, "Screen lights up on tap: off"),
    ("secure", "wake_gesture_enabled", "0", False, "Wake gesture: off"),
    ("secure", "screensaver_enabled", "0", False, "Screen saver: off"),
    ("secure", "refresh_rate_mode", "0", True, "Motion smoothness: Standard 60 Hz"),
    ("system", "screen_off_timeout", "30000", False, "Screen timeout: 30 seconds"),
    ("system", "haptic_feedback_enabled", "0", False, "Touch vibration: off"),
    ("system", "sound_effects_enabled", "0", False, "Touch sounds: off"),
    ("system", "dtmf_tone", "0", False, "Dial pad tones: off"),
    ("system", "lockscreen_sounds_enabled", "0", False, "Lock sounds: off"),
    ("system", "double_tab_to_wake_up", "0", True, "Double tap to turn on screen: off"),
    ("system", "lift_to_wake", "0", True, "Lift to wake: off"),
    ("system", "nearby_scanning_enabled", "0", True, "Nearby device scanning: off"),
    ("system", "edge_enable", "0", True, "Edge panels: off"),
]

# Deep sleep (Doze) timers in ms. Android's defaults wait many minutes and want the phone to lie still.
DOZE_CONSTANTS = {"light_after_inactive_to": "10000", "inactive_to": "30000", "sensing_to": "0",
                  "locating_to": "0", "motion_inactive_to": "0", "idle_after_inactive_to": "0"}

# START_FOREGROUND is left alone on purpose: denying it makes some apps crash and restart in a loop.
RESTRICT_OPS = ("RUN_ANY_IN_BACKGROUND", "RUN_IN_BACKGROUND", "WAKE_LOCK")

RADIOS = [  # (name, state command, on, off)
    ("Wi-Fi", "settings get global wifi_on", "svc wifi enable", "svc wifi disable"),
    ("Mobile data", "settings get global mobile_data", "svc data enable", "svc data disable"),
    ("Bluetooth", "settings get global bluetooth_on", "cmd bluetooth_manager enable", "cmd bluetooth_manager disable"),
    ("NFC", "dumpsys nfc | grep -m1 mState=", "svc nfc enable", "svc nfc disable"),
    ("Location", "cmd location is-location-enabled", "cmd location set-location-enabled true",
     "cmd location set-location-enabled false"),
]


# Read a JSON file from this computer, or return default if it is missing or broken.
def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)


def parse_marked(text):
    """{name: value} from lines of "#name=value"."""
    return dict(line[1:].split("=", 1) for line in text.splitlines() if line.startswith("#") and "=" in line)


def parse_user_whitelist(text):
    """Packages the user set to "Unrestricted" battery, from "dumpsys deviceidle whitelist"."""
    rows = (line.strip().split(",") for line in text.splitlines())
    return {r[1] for r in rows if len(r) >= 2 and r[0] == "user"}


# App user ids (UIDs) from 'cmd netpolicy list ...' output.
def parse_uid_list(text):
    return set(re.findall(r"\d+", text.split(":", 1)[1])) if ":" in text else set()


# Whether a radio's state command means 'on'.
def radio_on(out):
    out = out.strip()
    return out in ("1", "2", "true") or "mState=on" in out


# Current value of every setting the Battery tool changes, in one adb call.
def power_saver_command(on):
    """Android refuses to switch power saving while the phone charges, and over USB it always charges.
    So the charger is hidden from Android for a moment ("unplug" is only pretend, "reset" undoes it)."""
    return f"cmd battery unplug; cmd power set-mode {1 if on else 0}; cmd battery reset"


def power_saving_on():
    """While charging, Android pauses power saving and remembers it as "sticky": it returns when unplugged."""
    return "1" in adb("settings get global low_power; settings get global low_power_sticky")[1].split()[:2]


def parse_battery(text):
    """Level, temperature, health and estimated full capacity (mAh) from "dumpsys battery"."""
    def num(key):
        m = re.search(rf"^\s*{key}: (-?\d+)", text, re.M)
        return int(m[1]) if m else None
    level, temp, counter = num("level"), num("temperature"), num("Charge counter")
    health = {1: "unknown", 2: "good", 3: "overheated", 4: "dead", 5: "over voltage", 6: "failed", 7: "cold"}.get(num("health"))
    # charge counter is what is in the battery now (uAh); below 20% the estimate gets too rough
    capacity = round(counter / 1000 * 100 / level) if counter and counter > 0 and level and level >= 20 else None
    return {"level": level, "temp": temp / 10 if temp is not None else None, "health": health, "capacity": capacity}


def battery_line(text):
    b = parse_battery(text)
    parts = [f"{b['level']}%" if b["level"] is not None else "unknown"]
    if b["temp"] is not None:
        parts.append(f"{b['temp']:.1f} °C")
    if b["health"]:
        parts.append(f"health {b['health']}")
    if b["capacity"]:
        parts.append(f"about {b['capacity']} mAh when full (estimate)")
    return ", ".join(parts)


THERMAL = {"0": "normal", "1": "light heat", "2": "moderate heat", "3": "severe heat", "4": "critical heat",
           "5": "emergency", "6": "shutdown"}


def parse_wake_locks(text):
    """[(uid, tag)] of the wake locks held right now, from "dumpsys power". A wake lock keeps the processor awake.
    When a system service holds it for an app, the app's uid is in "WorkSource{...}" and wins."""
    locks = []
    for line in text.splitlines():
        m = re.search(r"PARTIAL_WAKE_LOCK\s+'([^']*)'.*?\(uid=(\d+)", line)
        if m:
            ws = re.search(r"WorkSource\{(\d+)", line)
            locks.append((ws[1] if ws else m[2], m[1]))
    return locks


def parse_power_use(text):
    """[(uid, mAh)] biggest first, from the "Estimated power use" lines of "dumpsys batterystats"."""
    use = {}
    for app, plain, mah in re.findall(r"^\s+U(?:ID|id) (?:u0a(\d+)|(\d+)): ([\d.]+)", text, re.M):
        uid = str(10000 + int(app)) if app else plain
        use[uid] = use.get(uid, 0) + float(mah)
    return sorted(use.items(), key=lambda u: -u[1])


def read_settings():
    out = adb("; ".join(f'echo "#{ns}/{key}=$(settings get {ns} {key})"' for ns, key, *_ in BATTERY_SETTINGS))[1]
    return parse_marked(out)


# Current deep sleep (Doze) timers.
def read_doze():
    return parse_marked(adb("; ".join(f'echo "#{k}=$(device_config get device_idle {k})"' for k in DOZE_CONSTANTS))[1])


# Dark mode state: "yes", "no" or "auto".
def night_mode():
    m = re.search(r"Night mode: (\w+)", adb("cmd uimode night")[1])
    return m[1] if m else None


# Run many phone commands, 50 per adb call, because each call is slow.
def run_all(commands):
    for start in range(0, len(commands), 50):
        adb("; ".join(commands[start:start + 50]))


# Apply BATTERY_SETTINGS, dark mode and power saving. Old values go into the backup first.
def apply_settings(backup):
    now = read_settings()
    commands, missing = [], []
    for ns, key, value, samsung, what in BATTERY_SETTINGS:
        old = now.get(f"{ns}/{key}", "null")
        if samsung and old == "null":
            missing.append(what)
        elif old != value:
            backup.setdefault("settings", {}).setdefault(f"{ns}/{key}", old)
            commands.append(f"settings put {ns} {key} {shlex.quote(value)}")
    night = night_mode()
    if night and night != "yes":
        backup.setdefault("night_mode", night)
        commands.append("cmd uimode night yes")
    if not power_saving_on():
        backup.setdefault("power_saver", "0")
        commands.append(power_saver_command(True))
    save_json(BACKUP_FILE, backup)  # saved before changing anything, so RESTORE works even if this stops halfway
    run_all(commands)
    after = read_settings()
    failed = [what for ns, key, value, samsung, what in BATTERY_SETTINGS
              if what not in missing and after.get(f"{ns}/{key}") != value]
    print(f"  Settings: {len(BATTERY_SETTINGS) - len(missing) - len(failed)} set, dark mode and power saving on.")
    for what in failed:
        print(f"  FAILED: {what}")
    if missing:
        print(f"  Not on this phone (skipped): {', '.join(missing)}")


# Make the phone enter deep sleep ~30 s after the screen turns off.
def apply_deep_sleep(backup):
    now = read_doze()
    commands = []
    for key, value in DOZE_CONSTANTS.items():
        if now.get(key) != value:
            backup.setdefault("device_config", {}).setdefault(key, now.get(key, "null"))
            commands.append(f"device_config put device_idle {key} {value}")
    save_json(BACKUP_FILE, backup)
    reason = first_error(*adb(commands[0])[1:]) if commands else ""
    run_all(commands[1:])
    failed = [k for k, v in read_doze().items() if v != DOZE_CONSTANTS[k]]
    if failed:
        # Newer Android only lets USB debugging change some of these flags. Nothing changed, so nothing to restore.
        for k in failed:
            backup.get("device_config", {}).pop(k, None)
        save_json(BACKUP_FILE, backup)
        print(f"  Deep sleep: this phone does not allow changing the sleep timers over USB ({reason}).")
        if power_saving_on():
            print("  No problem: power saving with quick doze is on, so the phone still goes into deep sleep")
            print("  right after the screen turns off. Keep power saving on to keep that.")
        else:
            print("  Turn on power saving instead (Settings in this menu, or MAX BATTERY): its quick doze puts")
            print("  the phone into deep sleep right after the screen turns off.")
    else:
        print("  Deep sleep: the phone now sleeps about 30 seconds after the screen turns off.")
        print("  Apps not on the keep list may show messages a few minutes late while the screen is off.")


# Packages that are currently not allowed to run in the background.
def restricted_now():
    out = adb("cmd appops query-op RUN_ANY_IN_BACKGROUND ignore")[1]
    return {line.strip() for line in out.splitlines() if "." in line and valid_package_name(line.strip())}


def battery_targets(keep):
    """Your apps and the safe preinstalled extras, minus the keep list and whatever the phone needs to work."""
    installed = package_names(adb("pm list packages")[1])
    user = user_packages()
    tiers = load_tiers()
    protect = essential_packages() | keep | ALWAYS_KEEP
    targets = sorted(p for p in installed if (p in user or tiers.get(p, (4, ""))[0] == 2)
                     and p not in protect and not PROTECTED_APPS.search(p))
    return targets, installed


# Stop every app that is not on the keep list from running or waking the phone in the background.
def restrict_packages(targets, backup):
    before = restricted_now()
    unrestricted = parse_user_whitelist(adb("dumpsys deviceidle whitelist")[1])
    # Only what the Battery tool changes is remembered, so RESTORE leaves apps you optimized before alone.
    backup["restricted"] = sorted(set(backup.get("restricted", [])) | (set(targets) - before))
    backup["whitelist_removed"] = sorted(set(backup.get("whitelist_removed", [])) | (set(targets) & unrestricted))
    save_json(BACKUP_FILE, backup)
    # am kill stops what runs right now without the "stopped" state of force-stop, so the app still works
    # normally when you open it. After that, the restrictions keep it asleep.
    in_batches(targets, lambda q: "; ".join(
        [f"cmd appops set {q} {op} ignore" for op in RESTRICT_OPS]
        + [f"am set-standby-bucket {q} restricted", f"dumpsys deviceidle whitelist -{q} >/dev/null 2>&1",
           f"am kill {q}"]))


def restrict_apps(keep, backup):
    targets, installed = battery_targets(keep)
    restrict_packages(targets, backup)
    kept = sorted(keep & installed)
    in_batches(kept, lambda q: "; ".join(
        [f"cmd appops set {q} {op} allow" for op in RESTRICT_OPS + ("START_FOREGROUND",)]
        + [f"am set-standby-bucket {q} active"]))
    done = len(set(targets) & restricted_now())
    print(f"  Apps: {done} of {len(targets)} restricted, {len(kept)} on the keep list left free.")
    if done < len(targets):
        print(f"  {len(targets) - done} refused the restriction (usually system parts that do not allow it).")


# {package: uid}. Mobile data rules work per uid, not per package.
def package_uids():
    return dict(re.findall(r"^package:(\S+) uid:(\d+)", adb("pm list packages -U")[1], re.M))


# UIDs on the Data Saver "whitelist" (always allowed) or "blacklist" (always blocked).
def uid_list(kind):
    return parse_uid_list(adb(f"cmd netpolicy list restrict-background-{kind}")[1])


# Whether Data Saver (no background mobile data) is on.
def data_saver_on():
    return "enabled" in adb("cmd netpolicy get restrict-background")[1]


# Turn on Data Saver, but let the keep list and essential apps still use background data.
def block_background_data(keep, backup):
    uids = package_uids()
    allow = {uids[p] for p in keep | ALWAYS_KEEP | essential_packages() if p in uids}
    new = allow - uid_list("whitelist")
    backup.setdefault("data_saver", data_saver_on())
    backup["data_allowed"] = sorted(set(backup.get("data_allowed", [])) | new)
    save_json(BACKUP_FILE, backup)
    run_all([f"cmd netpolicy add restrict-background-whitelist {u}" for u in sorted(new)]
            + ["cmd netpolicy set restrict-background true"])
    missing = allow - uid_list("whitelist")
    if data_saver_on():
        print(f"  Mobile data: no app uses mobile data in the background now, except {len(allow) - len(missing)} kept ones.")
        print("  Wi-Fi is not affected. Hotspot may not work while Data Saver is on.")
    else:
        print("  Mobile data: FAILED, Data Saver did not turn on.")
    if missing:
        print(f"  {len(missing)} kept apps could not be allowed. Check them under Mobile data per app.")


# The saved keep list, or None if the user never made one.
def load_keep():
    keep = load_json(KEEP_FILE, None)
    return set(keep) if isinstance(keep, list) else None


def choose_keep():
    """Pick the apps that must keep working. Returns the saved set, or None on Esc before saving."""
    apps_with_icon = parse_launcher_packages(adb("cmd package query-activities --brief -a android.intent.action.MAIN "
                                                 "-c android.intent.category.LAUNCHER")[1])
    choices = user_packages() | apps_with_icon
    apks = {p: apk for p, apk in parse_package_paths(adb("pm list packages -f")[1]).items() if p in choices}
    labels = load_labels(apks)
    saved = load_keep()
    keep = saved if saved is not None else SUGGESTED_KEEP & apks.keys()
    while True:
        apps = sorted(apks, key=lambda p: (p not in keep, (labels[p] or p).casefold()))
        rows = [("[KEEP] " if p in keep else "") + (f"{labels[p]} ({p})" if labels[p] else p) for p in apps]
        chosen = pick("Keep list", [f"[ SAVE, keeping {len(keep & apks.keys())} ]"] + rows,
                      "Enter = KEEP on or off | Tab = select several | Top row = save | Esc = back", multi=True)
        if not chosen:
            return saved
        if 0 in chosen:
            save_json(KEEP_FILE, sorted(keep))
            return keep
        keep ^= {apps[i - 1] for i in chosen}
        save_json(KEEP_FILE, sorted(keep))
        saved = keep


# The keep list, asking the user to make one first if there is none.
def need_keep():
    keep = load_keep()
    if keep is None:
        print("First choose the apps that must keep working in the background (messages, school, banking).")
        keep = choose_keep()
    return keep


# Menu: block or allow background mobile data app by app.
def data_per_app_menu(backup):
    print("Loading apps...")
    apks = parse_package_paths(adb("pm list packages -f")[1])
    user = user_packages()
    tiers = load_tiers()
    shown = {p: apk for p, apk in apks.items() if p in user or tiers.get(p, (4, ""))[0] == 2}
    labels = load_labels(shown)
    uids = package_uids()
    apps = sorted((p for p in shown if p in uids), key=lambda p: (labels[p] or p).casefold())
    print("Blocked apps cannot use mobile data in the background. In the foreground and on Wi-Fi they work normally.")
    while True:
        blocked = uid_list("blacklist")
        rows = [("[BLOCKED] " if uids[p] in blocked else "") + (f"{labels[p]} ({p})" if labels[p] else p) for p in apps]
        chosen = pick("Background mobile data", rows,
                      "Enter = block, or allow if [BLOCKED] | Tab = select several | Esc = back", multi=True)
        if not chosen:
            return
        commands, record = [], set(backup.get("data_blocked", []))
        for i in chosen:
            uid = uids[apps[i]]
            if uid in blocked:
                commands.append(f"cmd netpolicy remove restrict-background-blacklist {uid}")
                record.discard(uid)
            else:
                commands.append(f"cmd netpolicy add restrict-background-blacklist {uid}")
                record.add(uid)
        backup["data_blocked"] = sorted(record)
        save_json(BACKUP_FILE, backup)
        run_all(commands)


# Menu: switch Wi-Fi, mobile data, Bluetooth, NFC and location on or off.
def radios_menu():
    while True:
        states = [radio_on(adb(state)[1]) for _, state, _, _ in RADIOS]
        rows = [f"{'ON ' if on else 'OFF'}  {name}" for (name, *_), on in zip(RADIOS, states)]
        chosen = pick("Radios", rows, "Enter = switch on or off | Esc = back")
        if not chosen:
            return
        name, _, on_cmd, off_cmd = RADIOS[chosen[0]]
        adb(off_cmd if states[chosen[0]] else on_cmd)
        time.sleep(2)  # radios need a moment before they report the new state


# Checklist of what is applied right now.
# --- extra savers: stronger, optional, never applied by MAX BATTERY. RESTORE undoes them. ---

# Apps that only collect diagnostics or usage data. Disabled, not removed.
TELEMETRY_APPS = ("com.samsung.android.dqagent", "com.sec.android.diagmonagent", "com.samsung.android.rubin.app",
                  "com.nothing.logkit", "com.google.android.feedback", "com.miui.analytics", "com.miui.msa.global")


def net_types():
    """{SIM slot: allowed network types as a binary string}, from Android's own phone command."""
    out = adb('for s in 0 1; do echo "#$s=$(cmd phone get-allowed-network-types-for-users -s $s 2>/dev/null)"; done')[1]
    return {slot: m for slot, m in parse_marked(out).items() if re.fullmatch("[01]+", m)}


def has_5g(mask):
    """5G (NR) is network type 20, so bit 20 from the right."""
    return len(mask) >= 20 and mask[-20] == "1"


def set_5g(mask, on):
    mask = mask.zfill(20)
    return mask[:-20] + ("1" if on else "0") + mask[-19:]


def parse_display(text):
    """(width, height, density, override width or None) from "wm size; wm density"."""
    size, dens = re.search(r"Physical size: (\d+)x(\d+)", text), re.search(r"Physical density: (\d+)", text)
    over = re.search(r"Override size: (\d+)x", text)
    return (int(size[1]), int(size[2]), int(dens[1]), int(over[1]) if over else None) if size and dens else None


def display_sizes(w, h, modes):
    """The resolutions the phone's own selector offers, biggest first: [(width, height), ...].
    They come from the screen's supported modes ("dumpsys display"); no made-up sizes."""
    sizes = {w: h}
    for a, b in re.findall(r"width=(\d+), height=(\d+)", modes):
        mw, mh = sorted((int(a), int(b)))
        if mw <= w:
            sizes[mw] = mh
    # Samsung scales in software and reports one mode; its selector offers FHD+ and HD+ on 1440-wide screens.
    if len(sizes) == 1 and w == 1440:
        for mw in (1080, 720):
            sizes[mw] = int(h * mw / w / 2 + 0.5) * 2
    return sorted(sizes.items(), reverse=True)


def extras_menu(backup):
    while True:
        masks = net_types()
        installed, off = package_names(adb("pm list packages")[1]), package_names(adb("pm list packages -d")[1])
        tele = [p for p in TELEMETRY_APPS if p in installed]
        disp = parse_display(adb("wm size; wm density")[1])
        charge = adb("settings get global protect_battery")[1].strip()
        g_off = bool(masks) and not any(has_5g(m) for m in masks.values())
        tele_off = bool(tele) and all(p in off for p in tele)
        rows, acts = [], []
        if masks:
            rows.append(f"[{'ON ' if g_off else 'OFF'}] 5G off: use 4G, which needs less power, most of all with weak signal")
            acts.append("5g")
        if tele:
            rows.append(f"[{'ON ' if tele_off else 'OFF'}] Diagnostics apps off: {len(tele)} apps that only collect usage data")
            acts.append("tele")
        if disp:
            now = f"{disp[3]} wide" if disp[3] else "native"
            rows.append(f"      Screen resolution: {now} (pick one of the resolutions the phone offers)")
            acts.append("res")
        if charge in ("0", "1"):
            rows.append(f"[{'ON ' if charge == '1' else 'OFF'}] Limit charging to 85% (Samsung): longer battery lifespan, less runtime per charge")
            acts.append("charge")
        if not rows:
            print("This phone offers none of the extra savers over USB.")
            return
        chosen = pick("Extra savers", rows, "Optional, not part of MAX BATTERY | Enter = switch | RESTORE undoes them | Esc = back")
        if not chosen:
            return
        act = acts[chosen[0]]
        if act == "5g":
            saved, commands = backup.setdefault("net_types", {}), []
            for slot, m in masks.items():
                if g_off:   # back on: the saved value, or just the 5G bit
                    old = saved.pop(slot, None)
                    to = old if old and has_5g(old) else set_5g(m, True)
                else:
                    saved.setdefault(slot, m)
                    to = set_5g(m, False)
                commands.append(f"cmd phone set-allowed-network-types-for-users -s {slot} {to}")
            save_json(BACKUP_FILE, backup)
            run_all(commands)
            after = net_types()
            ok = bool(after) and (any(has_5g(m) for m in after.values()) == g_off)
            print(f"  5G is now {'allowed' if g_off else 'off'}." if ok else "  FAILED: the phone did not accept the change.")
        elif act == "tele":
            if tele_off:
                run_all([f"pm enable --user 0 {p}" for p in tele])
                backup.pop("telemetry_disabled", None)
            else:
                backup["telemetry_disabled"] = sorted(set(backup.get("telemetry_disabled", [])) | (set(tele) - off))
                save_json(BACKUP_FILE, backup)
                run_all([f"pm disable-user --user 0 {p}" for p in tele])
            save_json(BACKUP_FILE, backup)
        elif act == "res":
            w, h, d, _ = disp
            sizes = display_sizes(w, h, adb("dumpsys display | grep -i supportedModes")[1])
            if len(sizes) == 1:
                print(f"  This phone offers only one resolution ({w}x{h}).")
                if disp[3]:
                    adb("wm size reset; wm density reset")   # a custom size from an older version
                    print("  A custom size from an older version was active: the native one is back.")
                continue
            names = {720: "HD+ ", 1080: "FHD+ ", 1440: "WQHD+ "}
            pickd = pick("Resolution", [f"{names.get(sw, '')}{sw}x{sh_}{' (native)' if sw == w else ''}" for sw, sh_ in sizes],
                         "The resolutions this phone offers | Enter = set | Esc = back")
            if pickd:
                sw, sh_ = sizes[pickd[0]]
                backup["resolution"] = True
                save_json(BACKUP_FILE, backup)
                # density shrinks with the width so text and icons keep their size
                adb("wm size reset; wm density reset" if sw == w else f"wm size {sw}x{sh_}; wm density {int(d * sw / w + 0.5)}")
        elif act == "charge":
            saved = backup.setdefault("settings", {})
            if charge == "1":
                saved.pop("global/protect_battery", None)
            else:
                saved.setdefault("global/protect_battery", charge)
            save_json(BACKUP_FILE, backup)
            adb(f"settings put global protect_battery {'0' if charge == '1' else '1'}")


def battery_use_menu(backup):
    """Apps that used the most battery since the last full charge. Enter restricts the selected ones."""
    out = adb("dumpsys batterystats --charged | grep -E '^ +U(ID|id) [u0-9a]+: [0-9.]+'")[1]
    by_uid = {}
    for package, uid in sorted(package_uids().items()):
        by_uid.setdefault(uid, package)
    use = [(by_uid[uid], mah) for uid, mah in parse_power_use(out) if uid in by_uid and mah >= 0.1]
    screen = re.search(r"Screen on: (.*?) \(", adb("dumpsys batterystats --charged | grep -m1 'Screen on:'")[1])
    if screen:
        print(f"Screen on since the last full charge: {re.sub(r' ?[0-9]+ms', '', screen[1])}")
    locks = parse_wake_locks(adb("dumpsys power | grep WAKE_LOCK")[1])
    if locks:
        print("Keeping the phone awake right now:")
        for uid, tag in locks[:10]:
            print(f"  {by_uid.get(uid, 'Android system')} ({tag})")
    if not use:
        print("The phone has no battery use numbers yet. Use it off the charger for a while first.")
        return
    keep = load_keep() or set()
    apks = parse_package_paths(adb("pm list packages -f")[1])
    labels = load_labels({p: apks[p] for p, _ in use if p in apks})
    while True:
        restricted = restricted_now()
        rows = [f"{mah:8.1f} mAh  {'[KEEP] ' if p in keep else '[restricted] ' if p in restricted else ''}{labels.get(p) or p} ({p})"
                for p, mah in use]
        chosen = pick("Battery use since the last full charge", ["[ START A NEW MEASUREMENT: forget the numbers so far ]"] + rows,
                      "Biggest first | Enter = restrict | Tab = select several | Esc = back", multi=True)
        if not chosen:
            return
        if 0 in chosen:
            adb("dumpsys batterystats --reset")
            print("New measurement started. Use the phone off the charger, then look here again.")
            return
        picked = [use[i - 1][0] for i in chosen]
        selected = [p for p in picked if p not in keep and not PROTECTED_APPS.search(p)]
        if len(selected) < len(picked):
            print(f"  {len(picked) - len(selected)} skipped: on the keep list, or a part the phone needs.")
        if selected:
            restrict_packages(selected, backup)
            print(f"  Restricted {len(set(selected) & restricted_now())} of {len(selected)}. RESTORE undoes it.")


def sleep_now():
    """Screen off and straight into deep sleep, without waiting for Android's timers."""
    out = adb("input keyevent 223; dumpsys deviceidle force-idle")[1].strip()
    print(f"  {out.splitlines()[-1] if out else 'No answer from the phone.'}")
    print("  Deep sleep ends when you wake the phone. Apps on the keep list may get messages a little late until then.")


def battery_status(keep):
    print(f"\nBattery: {battery_line(adb('dumpsys battery')[1])}")
    thermal = re.search(r"Thermal Status: (\d)", adb("dumpsys thermalservice | grep -m1 'Thermal Status'")[1])
    if thermal:
        print(f"Temperature state: {THERMAL.get(thermal[1], thermal[1])} (heat wears the battery out faster)")
    screen = re.search(r"Screen on: (.*?) \(", adb("dumpsys batterystats --charged | grep -m1 'Screen on:'")[1])
    if screen:
        print(f"Screen on since the last full charge: {re.sub(r' ?[0-9]+ms', '', screen[1])}")
    power = power_saving_on()
    print(f"[{'x' if power else ' '}] Power saving on (paused while charging, back when unplugged)")
    print(f"[{'x' if night_mode() == 'yes' else ' '}] Dark mode on")
    print(f"[{'x' if data_saver_on() else ' '}] Background mobile data blocked (Data Saver)")
    doze = read_doze()
    if all(doze.get(k) == v for k, v in DOZE_CONSTANTS.items()):
        print("[x] Deep sleep after 30 seconds")
    else:
        print(f"[{'x' if power else ' '}] Deep sleep right after screen off (quick doze, needs power saving on)")
    if keep is not None:
        targets, _ = battery_targets(keep)
        done = len(set(targets) & restricted_now())
        print(f"[{'x' if done == len(targets) else ' '}] Apps restricted: {done} of {len(targets)} "
              f"({len(keep)} on the keep list)")
    else:
        print("[ ] Apps: no keep list yet")
    now = read_settings()
    for ns, key, value, samsung, what in BATTERY_SETTINGS:
        old = now.get(f"{ns}/{key}", "null")
        if samsung and old == "null":
            continue
        print(f"[{'x' if old == value else ' '}] {what}")
    ask("\nPress Enter to go back.")


# MAX BATTERY: settings, deep sleep, app restrictions and (optionally) mobile data in one go.
def max_battery():
    keep = need_keep()
    if keep is None:
        print("Cancelled.")
        return
    print(f"\nKeeping {len(keep)} apps free: {', '.join(sorted(keep)) or 'none'}")
    print("This turns on power saving, dark mode and deep sleep, switches off everything that drains")
    print("in the background, and restricts every other app. RESTORE in this menu undoes all of it.")
    if ask("Type GO to start: ") != "GO":
        print("Cancelled.")
        return
    backup = load_json(BACKUP_FILE, {})
    print("1/4 Settings...")
    apply_settings(backup)
    print("2/4 Deep sleep...")
    apply_deep_sleep(backup)
    print("3/4 Apps...")
    restrict_apps(keep, backup)
    print("4/4 Background mobile data...")
    if ask("  Block background mobile data for every app not on the keep list? [y/N] ").lower() == "y":
        block_background_data(keep, backup)
    else:
        print("  Skipped.")
    print("\nDone. Restart the phone once so the app freezer turns on.")
    print("Run MAX BATTERY again after installing new apps or after a system update.")


# RESTORE: put back every value saved in the backup file, then delete the backup.
def restore_all():
    backup = load_json(BACKUP_FILE, {})
    if not backup:
        print("The Battery tool has not changed anything yet.")
        return
    if ask("Undo everything the Battery tool changed? [y/N] ").lower() != "y":
        print("Cancelled.")
        return
    commands = []
    for name, old in backup.get("settings", {}).items():
        ns, key = name.split("/", 1)
        commands.append(f"settings delete {ns} {key}" if old == "null" else f"settings put {ns} {key} {shlex.quote(old)}")
    for key, old in backup.get("device_config", {}).items():
        commands.append(f"device_config delete device_idle {key}" if old == "null"
                        else f"device_config put device_idle {key} {shlex.quote(old)}")
    if backup.get("night_mode"):
        commands.append(f"cmd uimode night {shlex.quote(backup['night_mode'])}")
    if "power_saver" in backup and backup["power_saver"] != "1":
        commands.append(power_saver_command(False))
    commands += [f"cmd netpolicy remove restrict-background-whitelist {u}" for u in backup.get("data_allowed", [])]
    commands += [f"cmd netpolicy remove restrict-background-blacklist {u}" for u in backup.get("data_blocked", [])]
    if backup.get("data_saver") is False:
        commands.append("cmd netpolicy set restrict-background false")
    commands += [f"cmd phone set-allowed-network-types-for-users -s {slot} {m}" for slot, m in backup.get("net_types", {}).items()
                 if slot.isdigit() and re.fullmatch("[01]+", m)]
    commands += [f"pm enable --user 0 {shlex.quote(p)}" for p in backup.get("telemetry_disabled", [])]
    if backup.get("resolution"):
        commands.append("wm size reset; wm density reset")
    run_all(commands)
    in_batches(backup.get("restricted", []), lambda q: "; ".join(
        [f"cmd appops set {q} {op} default" for op in RESTRICT_OPS] + [f"am set-standby-bucket {q} active"]))
    in_batches(backup.get("whitelist_removed", []), lambda q: f"dumpsys deviceidle whitelist +{q} >/dev/null 2>&1")
    os.remove(BACKUP_FILE)
    print("Restored. Apps you optimized with the old optimize tool were left as they were.")
    print("Restart the phone once so the app freezer goes back to normal.")


# Top-level Battery menu.
def battery_menu():
    rows = [
        "MAX BATTERY          do everything below in one go",
        "Keep list            apps that must keep working (messages, school, banking)",
        "Apps                 restrict every app that is not on the keep list",
        "Mobile data          block background mobile data, except the keep list",
        "Mobile data per app  block or allow background mobile data app by app",
        "Settings             power saving, dark mode, no AOD, no scanning, no wake gestures",
        "Deep sleep           sleep 30 seconds after the screen turns off",
        "Radios               Wi-Fi, mobile data, Bluetooth, NFC, location on or off",
        "Extra savers         optional: 5G off, diagnostics apps off, lower resolution, charge limit",
        "Battery use          which apps used the most battery since the last charge",
        "Sleep now            screen off and straight into deep sleep",
        "Status               what is applied right now",
        "RESTORE              undo everything the Battery tool changed",
    ]
    while True:
        chosen = pick("Battery", rows, "Enter = open | Esc = quit")
        if not chosen:
            return
        name = rows[chosen[0]].split("  ")[0].strip()
        backup = load_json(BACKUP_FILE, {})
        if name == "MAX BATTERY":
            max_battery()
        elif name == "Keep list":
            choose_keep()
        elif name in ("Apps", "Mobile data"):
            keep = need_keep()
            if keep is None:
                continue
            if name == "Apps":
                restrict_apps(keep, backup)
            else:
                block_background_data(keep, backup)
        elif name == "Mobile data per app":
            data_per_app_menu(backup)
        elif name == "Settings":
            apply_settings(backup)
        elif name == "Deep sleep":
            apply_deep_sleep(backup)
        elif name == "Radios":
            radios_menu()
        elif name == "Extra savers":
            extras_menu(backup)
        elif name == "Battery use":
            battery_use_menu(backup)
        elif name == "Sleep now":
            sleep_now()
        elif name == "Status":
            battery_status(load_keep())
        elif name == "RESTORE":
            restore_all()


# --- self-check: tiny fake APK data and asserts for the parsers. Run: ./battery-optimizer-linux.sh selfcheck ---

def fake_pool(strings):
    """Build a UTF-8 string pool for the self-check."""
    body, offsets = b"", []
    for text in strings:
        offsets.append(len(body))
        raw = text.encode()
        body += bytes([len(text), len(raw)]) + raw + b"\0"
    body += b"\0" * (-len(body) % 4)
    start = 28 + 4 * len(strings)
    head = struct.pack("<HHIIIIII", 1, 28, start + len(body), len(strings), 0, 0x100, start, 0)
    return head + struct.pack(f"<{len(strings)}I", *offsets) + body


def fake_manifest(kind, value):
    pool = fake_pool(["application", "label", "Literal Name"])
    attr = struct.pack("<IIIHBBI", 0xFFFFFFFF, 1, 2 if kind == 3 else 0xFFFFFFFF, 8, 0, kind, value)
    element = struct.pack("<HHIIIIIHHHHHH", 0x102, 16, 36 + len(attr), 1, 0xFFFFFFFF, 0xFFFFFFFF, 0,
                          20, 20, 1, 0, 0, 0) + attr
    return struct.pack("<HHI", 3, 8, 8 + len(pool) + len(element)) + pool + element


def fake_table(locale, string_index):
    config = struct.pack("<I", 8 + 28)[:4] + b"\0" * 4 + locale + b"\0" * 26
    start = 20 + len(config) + 4
    entry = struct.pack("<HHIHBBI", 8, 0, 0, 8, 0, 3, string_index)
    return struct.pack("<HHIBBHII", 0x201, 20 + len(config), start + len(entry), 1, 0, 0, 1, start) \
        + config + struct.pack("<I", 0) + entry


def fake_resources():
    pool = fake_pool(["Default Name", "Deutscher Name"])
    tables = fake_table(b"\0\0", 0) + fake_table(b"de", 1)
    package = struct.pack("<HHII", 0x200, 288, 288 + len(tables), 0x7F) + b"\0" * 276 + tables
    return struct.pack("<HHII", 2, 12, 12 + len(pool) + len(package), 1) + pool + package


# Tests the text parsers without a phone.
def self_check():
    states = "=com.a\nPOST_NOTIFICATION: ignore; time=+1s\n=com.b\nNo operations.\n=com.c\nPOST_NOTIFICATION: allow\n"
    assert parse_notifications_off(states) == {"com.a"}
    assert parse_available_mb("MemTotal: 9 kB\nMemAvailable:    2048 kB\n") == 2
    assert parse_available_mb("nothing") is None
    services = "  * ServiceRecord{1 u0 com.a/.S}\n    isForeground=false\n  * ServiceRecord{2 u0 com.b/.T}\n    isForeground=true x\n"
    assert parse_foreground_packages(services) == {"com.b"}
    assert parse_running_packages("NAME\ncom.a:push\ncom.a\ninit\ncom.b\n") == {"com.a", "com.b"}
    assert package_names("package:a.b\nnoise\npackage:c\n") == {"a.b", "c"}
    assert first_error("", "Exception occurred while executing 'x':\njava.lang.Foo: nope\n\tat y") == "java.lang.Foo: nope"
    assert first_error("", "") == "no reason given"
    assert valid_package_name("com.miui.analytics") and valid_package_name("android")
    assert not valid_package_name("com.x; reboot") and not valid_package_name("com..x") and not valid_package_name("com.x/.Svc")
    assert parse_ime_packages("com.a.kb/.Svc\ncom.b.kb/com.b.kb.Svc\nnoise\n") == ["com.a.kb", "com.b.kb"]
    assert manifest_label(fake_manifest(3, 2)) == "Literal Name"
    assert manifest_label(fake_manifest(1, 0x7F010000)) == 0x7F010000
    assert resource_string(fake_resources(), 0x7F010000, b"en") == "Default Name"
    assert resource_string(fake_resources(), 0x7F010000, b"de") == "Deutscher Name"
    assert parse_package_paths("package:/a=b/base.apk=com.x\nnoise\n") == {"com.x": "/a=b/base.apk"}
    assert parse_launcher_packages("2 activities found:\n  com.x.y/.Main\n  priority=0 x\n") == {"com.x.y"}
    tiers = parse_tiers("2 com.calc Calculator\n3 com.gms Play Services\n4 com.bad X\nnoise\n")
    assert tiers == {"com.calc": (2, "Calculator"), "com.gms": (3, "Play Services")}
    apks = dict.fromkeys(["com.gms", "com.core", "com.calc", "com.mine", "com.coreoff"], "x")
    entries = disable_entries(apks, {"com.mine": "Mine"}, set(), {"com.coreoff"}, {"com.mine"}, tiers)
    assert [p for _, p in entries] == [None, "com.mine", None, "com.calc", None, "com.gms", None, "com.coreoff"]
    assert disable_entries({"com.calc": "x"}, {"com.calc": "[Çåļç one]"}, set(), set(), set(), tiers)[1][0] == "[service] Calculator (com.calc)"
    assert entries[2][0] == "----- PREINSTALLED EXTRAS - safe -----" and entries[3][0] == "[service] Calculator (com.calc)"
    dump = ("  Package [com.a] (1):\n    requested permissions:\n      android.permission.CAMERA\n"
            "      android.permission.RECORD_AUDIO: restricted=true\n    install permissions:\n"
            "      android.permission.INTERNET: granted=true\n    User 0: ceDataInode=1 installed=true\n"
            "      gids=[3003]\n      runtime permissions:\n"
            "        android.permission.CAMERA: granted=true, flags=[ USER_SET]\n"
            "        android.permission.RECORD_AUDIO: granted=false, flags=[ ]\n    User 10: installed=true\n"
            "      runtime permissions:\n        android.permission.RECORD_AUDIO: granted=true, flags=[ ]\n"
            "  Package [com.b] (2):\n    requested permissions:\n      android.permission.PACKAGE_USAGE_STATS\n")
    perms = parse_permissions(dump)
    assert perms["com.a"] == ({"android.permission.CAMERA", "android.permission.RECORD_AUDIO", "android.permission.INTERNET"},
                              {"android.permission.INTERNET", "android.permission.CAMERA"})
    assert "android.permission.INTERNET" in parse_permissions(dump.replace("    requested permissions:\n", "", 1))["com.a"][0]
    assert parse_special_requests("#com.a android.permission.WRITE_SETTINGS\n#com.b\nnoise\n") == {
        "com.a": ["android.permission.WRITE_SETTINGS"], "com.b": []}
    assert permission_holders("CAMERA", None, perms, {}) == {"com.a": True}
    assert permission_holders("RECORD_AUDIO", None, perms, {}) == {"com.a": False}
    op_modes = parse_op_modes("#GET_USAGE_STATS allow\n  com.b\n#GET_USAGE_STATS deny\nNo operations.\n")
    assert op_modes == {"GET_USAGE_STATS": {"com.b": "allow"}}
    usage = ("GET_USAGE_STATS", "ignore")
    assert permission_holders("PACKAGE_USAGE_STATS", usage, perms, op_modes) == {"com.b": True}
    assert permission_holders("PACKAGE_USAGE_STATS", usage, perms, {"GET_USAGE_STATS": {"com.b": "ignore"}}) == {"com.b": False}
    assert permission_holders("PACKAGE_USAGE_STATS", usage, perms, {}) == {"com.b": False}
    assert package_row("com.x", "", set(), False) == "[service] com.x"
    assert package_row("com.x", "X", {"com.x"}, False) == "[app] X (com.x)"
    assert package_row("com.x", "X", set(), True) == "[OFF] X (com.x)"
    assert PROTECTED_APPS.search("com.android.phone") and PROTECTED_APPS.search("com.miui.home")
    rows = parse_rows("Row: 0 _id=5, display_name=Doe, Jane\nRow: 1 _id=6, display_name=Bob\nnoise")
    assert rows == [{"_id": "5", "display_name": "Doe, Jane"}, {"_id": "6", "display_name": "Bob"}]
    assert content_label({"number": "123", "date": "junk"}, ["number", "date"]) == "123  junk"
    assert matches_category(FILE_CATEGORIES["Photos"], "/sdcard/DCIM/A.JPG")
    assert not matches_category(FILE_CATEGORIES["Photos"], "/sdcard/a.pdf")
    assert matches_category(FILE_CATEGORIES["Trash & thumbnails"], "/sdcard/Android/.Trash/gallery/x")
    assert matches_category(FILE_CATEGORIES["Downloads"], "/sdcard//Download/x.bin")
    assert setting_category("wifi_on") == "Wi-Fi"
    assert setting_category("enable_foo") == SETTINGS_OTHER
    for key in ("adb_enabled", "device_provisioned", "user_setup_complete", "android_id", "default_input_method"):
        assert PROTECTED_SETTINGS.search(key), key
    assert not PROTECTED_SETTINGS.search("wifi_on")
    assert parse_settings("a.b=1\nnot a setting\nc=x=y\n") == [("a.b", "1"), ("c", "x=y")]
    assert matches_category(FILE_CATEGORIES["SD card"], "/storage/ABCD-1234/a.bin")
    assert not matches_category(FILE_CATEGORIES["SD card"], "/sdcard/a.bin")
    assert matches_category(FILE_CATEGORIES["Downloads"], "/storage/ABCD-1234/Download/a.bin")
    assert content_label({"title": "Dentist", "dtstart": "junk"}, ["title", "dtstart"]) == "Dentist  junk"
    assert PROTECTED_APPS.search("com.android.providers.telephony") and PROTECTED_APPS.search("android")
    assert not PROTECTED_APPS.search("com.android.chrome")
    wifi = "Network Id SSID Security type\n0  My Home Wifi  wpa2-psk\n0  My Home Wifi  wpa3-sae^\n1  Cafe  owe \n"
    assert parse_wifi_networks(wifi) == [("0", "My Home Wifi"), ("1", "Cafe")]
    assert parse_marked("#global/a=1\n#global/b=x=y,z=1\nnoise\n") == {"global/a": "1", "global/b": "x=y,z=1"}
    assert parse_user_whitelist("system-excidle,com.s,1000\nuser,com.u,10123\n") == {"com.u"}
    assert parse_uid_list("Restrict background whitelisted UIDs: 10123 10456\n") == {"10123", "10456"}
    assert parse_uid_list("nothing") == set()
    assert radio_on("1\n") and radio_on("true") and radio_on("  mState=on") and not radio_on("0") and not radio_on("mState=off")
    assert len({(ns, key) for ns, key, *_ in BATTERY_SETTINGS}) == len(BATTERY_SETTINGS)
    versions = [{"versionCode": "30", "minSdkVersion": "34"}, {"versionCode": "20", "nativecode": ["x86"]},
                {"versionCode": "10", "nativecode": ["arm64-v8a"]}, {"versionCode": "40"}]
    assert pick_version(versions, 33, ["arm64-v8a"], suggested=30)["versionCode"] == "10"
    assert pick_version(versions, 34, ["arm64-v8a"], suggested=30)["versionCode"] == "30"
    assert pick_version(versions, 33, ["arm64-v8a"])["versionCode"] == "40"
    assert pick_version([{"versionCode": "5", "minSdkVersion": "40"}], 33, ["arm64-v8a"]) is None
    assert safe_backup_path("Android/obb/com.a/main.obb", "com.a") and safe_backup_path("Android/data/com.a/f/x.db", "com.a")
    assert not safe_backup_path("Android/data/com.b/x", "com.a") and not safe_backup_path("Android/data/com.a/../../DCIM/x", "com.a")
    assert not safe_backup_path("DCIM/x.jpg", "com.a") and not safe_backup_path(None, "com.a")
    assert f"{'':>8}  Game A (com.a)"[10:].rsplit(" (", 1)[0] == "Game A"
    assert f"{fmt_size(999_000_000):>8}  Game A (com.a)"[10:].rsplit(" (", 1)[0] == "Game A"
    stats = "  Estimated power use (mAh):\n    UID u0a213: 45.6 fg: 1 ( cpu=2 )\n    UID 1000: 12.5\n    Uid u0a7: 0.5\n  u0a213:\n    Wake lock x\n"
    assert parse_power_use(stats) == [("10213", 45.6), ("1000", 12.5), ("10007", 0.5)]
    batt = parse_battery("  level: 80\n  health: 2\n  temperature: 315\n  Charge counter: 3600000\n")
    assert batt == {"level": 80, "temp": 31.5, "health": "good", "capacity": 4500}
    assert parse_battery("level: 10\nCharge counter: 400000\n")["capacity"] is None and parse_battery("")["level"] is None
    assert "set-mode 1" in power_saver_command(True) and power_saver_command(False).endswith("cmd battery reset")
    lte_nr = "10001000000000000000"   # bit 20 = 5G, bit 16 = some 4G type
    assert has_5g(lte_nr) and not has_5g(set_5g(lte_nr, False)) and set_5g(lte_nr, False) == "00001000000000000000"
    assert set_5g(set_5g(lte_nr, False), True) == lte_nr and not has_5g("1111") and has_5g(set_5g("1111", True))
    assert set_5g("1" * 32, False) == "1" * 12 + "0" + "1" * 19
    shown = "Physical size: 1080x2412\nOverride size: 810x1809\nPhysical density: 420\nOverride density: 315\n"
    assert parse_display(shown) == (1080, 2412, 420, 810) and parse_display("Physical size: 1080x2412\nPhysical density: 420\n")[3] is None
    assert parse_display("error") is None
    modes = "mSupportedModes=[{id=1, width=1440, height=3120, fps=120.0}, {id=2, width=1080, height=2340, fps=120.0}, {id=3, width=1080, height=2340, fps=60.0}]"
    assert display_sizes(1440, 3120, modes) == [(1440, 3120), (1080, 2340)]
    assert display_sizes(1080, 2412, "supportedModes [{id=1, width=1080, height=2412, fps=60.0}]") == [(1080, 2412)]
    assert display_sizes(1440, 3088, "") == [(1440, 3088), (1080, 2316), (720, 1544)]
    held = ("  PARTIAL_WAKE_LOCK              'AudioMix' ACQ=-1m2s (uid=1041 pid=0)\n"
            "  PARTIAL_WAKE_LOCK 'job/x' ACQ=-3s (uid=1000 pid=1 ws=WorkSource{10213 com.a})\n  SCREEN_BRIGHT_WAKE_LOCK 'w' (uid=1000 pid=2)\n")
    assert parse_wake_locks(held) == [("1041", "AudioMix"), ("10213", "job/x")] and parse_wake_locks("") == []
    assert full_uninstall("'com.a'").startswith("pm uninstall 'com.a'; for u in $(pm list users")
    assert "UserInfo{[0-9]*'" in full_uninstall("x") and full_uninstall("x").endswith("do pm uninstall --user $u x; done")
    assert fmt_size(999) == "999 B" and fmt_size(1500) == "1.5 KB" and fmt_size(250_000_000) == "250 MB"
    print("self-check ok")


# --- F-Droid store: open-source apps, downloaded on this computer and installed with adb ---

FDROID = "https://f-droid.org/repo/"
FDROID_INDEX = os.path.expanduser("~/.cache/phone-fdroid-index-v1.jar")


def download(url, path, label):
    """Download to path with a progress line. A .part file keeps a broken download from replacing a good one."""
    with urllib.request.urlopen(url, timeout=60) as r, open(path + ".part", "wb") as f:
        total, done = int(r.headers.get("Content-Length") or 0), 0
        while chunk := r.read(1 << 16):
            f.write(chunk)
            done += len(chunk)
            if total:
                print(f"\r{label} {done * 100 // total}%   ", end="", flush=True)
    print()
    os.replace(path + ".part", path)


def fdroid_index():
    """F-Droid's app list, downloaded at most once a day."""
    # shortcut: the index comes over HTTPS but its jar signature is not checked; each APK is checked against its sha256.
    if not os.path.exists(FDROID_INDEX) or time.time() - os.path.getmtime(FDROID_INDEX) > 86400:
        os.makedirs(os.path.dirname(FDROID_INDEX), exist_ok=True)
        try:
            download(FDROID + "index-v1.jar", FDROID_INDEX, "Downloading the F-Droid app list")
        except OSError as e:
            if not os.path.exists(FDROID_INDEX):
                raise PhoneError(f"could not download the F-Droid app list: {e}")
            print(f"Could not update the F-Droid app list ({e}), using the saved one.")
    with zipfile.ZipFile(FDROID_INDEX) as z:
        return json.loads(z.read("index-v1.json"))


def pick_version(versions, sdk, abis, suggested=None):
    """Newest version that runs on this phone (Android version and processor), preferring stable over beta."""
    fits = [v for v in versions if int(v.get("minSdkVersion", 1)) <= sdk <= int(v.get("maxSdkVersion", 10 ** 6))
            and (not v.get("nativecode") or set(v["nativecode"]) & set(abis))]
    fits.sort(key=lambda v: -int(v["versionCode"]))
    stable = [v for v in fits if suggested is None or int(v["versionCode"]) <= suggested]
    return (stable or fits or [None])[0]


def install_from_fdroid(name, version):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "app.apk")
        try:
            download(FDROID + version["apkName"], path, f"  Downloading {name} {version.get('versionName', '')}")
        except OSError as e:
            print(f"  FAILED: {name}: download failed: {e}")
            return
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        if version.get("hashType", "sha256") != "sha256" or digest != version.get("hash"):
            print(f"  FAILED: {name}: the download does not match F-Droid's checksum, not installed.")
            return
        r = subprocess.run(["adb", "install", "-r", path], capture_output=True, text=True, errors="replace")
        out = (r.stdout + r.stderr).strip()
        print(f"  installed: {name}" if "Success" in out else f"  FAILED: {name}: {out.splitlines()[-1] if out else 'no answer'}")


def store_menu():
    try:
        index = fdroid_index()
    except (PhoneError, OSError, ValueError, zipfile.BadZipFile) as e:
        print(f"Store not available: {e}")
        return
    sdk = int(adb("getprop ro.build.version.sdk")[1].strip() or 0)
    abis = adb("getprop ro.product.cpu.abilist")[1].strip().split(",")
    apps = []
    for a in index.get("apps", []):
        loc = a.get("localized", {}).get("en-US", {})
        suggested = a.get("suggestedVersionCode")
        apps.append((a.get("name") or loc.get("name") or a["packageName"], a.get("summary") or loc.get("summary") or "",
                     a["packageName"], int(suggested) if suggested else None))
    apps.sort(key=lambda x: x[0].casefold())
    while True:
        installed = package_names(adb("pm list packages")[1])
        rows = [f"{'[installed] ' if p in installed else ''}{n}  -  {s} ({p})" for n, s, p, _ in apps]
        chosen = pick("F-Droid", rows, "Type to search | Enter = install or update | Tab = select several | Esc = back", multi=True)
        if not chosen:
            return
        for i in chosen:
            name, _, pkg, suggested = apps[i]
            version = pick_version(index.get("packages", {}).get(pkg, []), sdk, abis, suggested)
            if version:
                install_from_fdroid(name, version)
            else:
                print(f"  {name}: no version of this app runs on this phone.")
        ask("Press Enter to go back to the list.")


# Entry point of the Python part: check tools and phone, then open the requested menu.
def main():
    if sys.argv[1:] == ["--self-check"]:
        return self_check()
    for tool in ("adb", "fzf"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is not installed.")
    require_phone()
    if os.environ.get("PHONE_VERIFIED") != "1" and not verify_lock("One check before anything is shown or changed."):
        sys.exit(1)
    if sys.argv[1:] == ["--verify"]:
        return
    try:
        if sys.argv[1:] == ["--battery"]:
            battery_menu()
        elif sys.argv[1:] == ["--permissions"]:
            permissions_menu()
        elif sys.argv[1:] == ["--store"]:
            store_menu()
        else:
            main_menu()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
PY
"${PYTHON:-python3}" -X utf8 "$py" "$@"
rc=$?
rm -f "$py"
return $rc
}

# Entry point of the script: no argument opens the main menu, otherwise go straight to one tool.
case "$1" in
    "")
        # One entry point: every phone tool is a row in this menu and opens its own menu.
        cleanup --verify || exit 1   # the screen lock, once; the tools below then skip it
        export PHONE_VERIFIED=1
        while choice=$(printf '%s\n' \
            "Battery        maximum battery life: apps, settings, deep sleep, mobile data" \
            "Optimize       stop apps running in the background" \
            "Unoptimize     allow optimized apps again" \
            "Autostart      choose which apps may start when the phone boots" \
            "Permissions    see and change which apps have which permission" \
            "Cleanup        delete files and data, disable apps, notifications" \
            "Store          install open-source apps from F-Droid" \
            "Help           what every tool does" \
            | fzf --height=40% --reverse --prompt="phone > " --header="Enter = open | Esc = quit"); do
            case "$choice" in
                Battery*)     "$self" battery;;
                Optimize*)    "$self" optimize;;
                Unoptimize*)  "$self" unoptimize;;
                Autostart*)   "$self" autostart;;
                Permissions*) "$self" permissions;;
                Cleanup*)     "$self" cleanup;;
                Store*)       "$self" store;;
                Help*)        phonehelp | less;;
            esac
        done;;
    optimize|unoptimize|autostart) [ "$PHONE_VERIFIED" = 1 ] || cleanup --verify || exit 1; appops menu "$1";;
    battery)     cleanup --battery;;
    permissions) cleanup --permissions;;
    cleanup)     cleanup;;
    store)       cleanup --store;;
    install)     install_apk "$2";;
    help)        phonehelp;;
    _appops)     shift; appops "$@";;
    selfcheck)   cleanup --self-check;;
    *)           echo "usage: $0 [battery|optimize|unoptimize|autostart|permissions|cleanup|store|install FILE.apk|help]" >&2; exit 1;;
esac
