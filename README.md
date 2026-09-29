<p align="center">
  <img src="Assets/icon-512.png" width="160" alt="Mog app icon">
</p>

<h1 align="center">Mog</h1>

<p align="center">
  <b>Locks your Mac the moment someone else looks at it.</b><br>
  Offline face recognition in your menu bar. Nothing leaves your Mac.
</p>

<p align="center">
  <a href="https://github.com/c4rb0nx1/mog/tags"><img alt="Version" src="https://img.shields.io/github/v/tag/c4rb0nx1/mog?label=version&color=2e5d52"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-2e5d52">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-2e5d52">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-2e5d52"></a>
</p>

---

You step away for coffee. A colleague leans over your laptop. About a second later the screen locks, and if you want, their face is waiting on the lock screen when you come back.

Walking away never locks. Only a face that isn't yours does.

## Install

```bash
brew install c4rb0nx1/tap/mog
mog install-app
```

Open **Mog** from `~/Applications`, choose **Enroll My Face…**, then **Turn On** before you leave.

Homebrew builds Mog from source with the Command Line Tools in about a minute. It downloads the 110 MB face model once, checks it against a pinned SHA-256, and compiles it for your Mac. After that, Mog never touches the network.

## What it does

| | |
|---|---|
| 👁️ **Knows your face** | ArcFace, a proper face-recognition model, not a "looks similar" guess. In testing, the owner scored 0.6–0.98 and other people below 0.33. |
| ⚡ **Locks in about a second** | A stranger alone in view for 1 s locks the screen. Turning your own head away doesn't count. |
| 🚶 **Ignores an empty room** | Leaving your desk isn't a threat. Mog only reacts to a face that isn't yours, or to someone using the Mac while nobody's in view. |
| ⌨️ **Catches hands, not just faces** | Someone ducks out of view and types, clicks or touches the trackpad? With nobody in front of the camera, any touch locks the Mac at once, no countdown. On by default; switch it off in the menu. |
| 🥷 **Stealth mode** *(optional)* | Camera off, green light off, until someone types, clicks or touches the trackpad. Then Mog takes one look: you, and the camera goes off again; anyone else, or nobody, and the Mac locks at once, no countdown. |
| 🤝 **You're in charge** | If you're in frame, nothing locks, even with someone looking over your shoulder. |
| 🔴 **Warns first** | For a stranger in view, a red banner with a countdown shows on every screen before it locks. A touch with nobody in view locks at once, no warning. |
| 📸 **Intruder photo** *(optional)* | The face that triggered the lock becomes your lock-screen background. The biggest face that isn't yours, usually the person nearest the screen, stays sharp; everyone else and the room are blurred. Your wallpaper comes back when you unlock. |
| 🔁 **No lock loops** | After locking, Mog switches itself off. You turn it back on; it never re-arms behind your back. |
| 🛡️ **Only you can switch it off** | While Mog is watching, Turn Off, Quit, Re-enroll and Forget only work with you in front of the camera. Anyone else trying locks the Mac instead. |
| 🔒 **Private by design** | No images are stored for your profile, only 512 numbers per sample. No network, no accounts, no telemetry. |

## How it works

```text
camera ──► Vision finds faces ──► align to 112×112 ──► ArcFace → 512 numbers ──► you / unsure / stranger ──► guard ──► lock
```

1. **Detect.** Apple Vision finds every face in the frame, with eye and mouth landmarks.
2. **Align.** Each face is rotated and scaled onto ArcFace's standard layout, so eyes and mouth always land in the same place.
3. **Identify.** ArcFace turns the face into 512 numbers, which Mog compares with your enrolled samples:
   - **0.40 or higher**: you.
   - **Below 0.33**: someone else.
   - **In between**: unsure. This never starts a countdown, and it covers you at awkward angles.

   In a live test with the owner and two other people: owner 0.40–0.98, others −0.03 to 0.32.
4. **Decide.** A small state machine (`Sources/MogCore/Guard.swift`) locks in two cases:
   - **A stranger** is in view without you, across at least 3 camera frames: a 1-second countdown, then lock. One-frame flickers don't reset the countdown, and a couple of stray misreads can't trigger it. You appearing in view cancels it.
   - **Someone types, clicks or touches the trackpad with nobody in view**: lock at once, on the next camera frame (about 0.25 s). Only touches made after the last frame that showed any face count, so typing while you're in view never locks. But if you look away from the camera, or duck out of view, and touch the Mac, it locks, you included. Mog reads only *when* the last input happened, never *which* key, so it needs no Input Monitoring permission.

### Stealth mode

The camera's green light can't be turned off: Apple wires it to the camera. Stealth mode keeps the camera off instead, until the Mac is touched.

1. **Camera off.** Mog watches only the system's "last input" timers: key presses, clicks, pointer movement, scrolling, trackpad gestures.
2. **Touch.** The camera switches on. A cold camera shows a recognizable face after about 1 second.
3. **Verdict.**
   - **You**: the camera goes off. You're trusted while you keep using the Mac.
   - **Someone else**, for 2 frames in a row: the Mac locks at once.
   - **Nobody identifiable within 2.5 s**: the Mac locks. Someone is using it out of view.
4. **Re-check.** After 10 s untouched, the next touch is checked again. During nonstop use, Mog checks at least every 5 minutes, so someone who takes over the moment you stand up still gets caught.

Trade-offs: someone who only *looks* at the screen without touching anything isn't caught. Turning Mog off also needs a quick look, so the light flashes then. And if you work out of the camera's view (lid closed, docked), every first touch locks. Don't use stealth mode that way.

## Menu bar

The eye in your menu bar is the whole interface:

- **Turn On / Turn Off.** It arms 3 seconds after you turn it on.
- **Dock icon while watching.** The Mog icon appears in the Dock whenever it's guarding. Right-click it for Turn Off and Quit, even if the menu-bar icon is hidden behind the notch.
- **You have to be there to switch it off.** While watching, Turn Off and Quit work only if Mog has seen you in the last 2 seconds, from the menu bar, the Dock or ⌘Q. Otherwise the Mac locks instead, and Mog switches itself off as after any lock. Logging out and shutting down are never blocked.
- **Status line.** Shows what Mog sees right now: *You're here (match 0.91)*, *Nobody in view*, or *Stranger in view. Locking in 1 s*.
- **Enroll My Face…** Opens a live camera preview. Look at the screen and move your head slightly; it takes about 10 seconds.
- **Show Intruder Photo on Lock Screen.** Off by default. **Open Intruder Photos** browses the saved ones.
- **Lock on Typing When Nobody’s There.** On by default. Untick it if you often type while out of the camera's view, for example with an external keyboard and the lid closed. Stealth mode has this rule built in, so the switch is greyed out there.
- **Stealth Mode (Camera Off Until Touched).** Off by default. The menu-bar eye shows as a circled eye while stealth is on. Changes take effect the next time you turn Mog on.
- **Check for Updates…** Asks GitHub for the latest version, only when you click. If there's a newer one, the item changes to *Update Available: 0.x.y…*, and **Update in Terminal** opens Terminal to run `brew upgrade` and `mog install-app` where you can watch it. Mog quits for the update and reopens when it's done. While Mog is watching, updating needs you in view, like quitting.

The first time you turn it on, macOS asks for camera access for Mog.

## Command line

Everything the app does, plus diagnostics:

```bash
mog enroll          # record your face (sit alone, look at the screen)
mog test            # dry run: prints OWNER / STRANGER 0.xx per frame, never locks
mog watch           # guard for real; locks once, then exits
mog watch --photo   # ...and put the intruder's photo on the lock screen
mog watch --stealth # camera off until the Mac is touched, then one look; locks at once
mog test --stealth  # dry run of stealth: checks once at start and shows the timing
mog status          # camera permission, lock service, model, profile
mog probe           # 8-second camera check: detection, alignment, stability
mog lock-test       # lock the screen in 3 s to check the lock path
mog intruders       # list saved intruder photos
mog wallpaper-check # swap in a test picture for 3 s and put your wallpaper back
mog update          # check for a newer version and upgrade with Homebrew
```

Tuning:

| Flag | Default | Effect |
|---|---|---|
| `--grace S` | `1` | Seconds a stranger must stay in view before lock. |
| `--threshold X` | `0.40` | Match score at or above which a face is you. |
| `--stranger X` | `0.33` | Match score below which a face is a stranger. Lower means fewer false alarms but more room for a lookalike. |
| `--no-input-lock` | on | Don't lock on a key press, click or trackpad touch while nobody is in view. |
| `--stealth` | off | Camera off until someone touches the Mac. `--grace` and `--no-input-lock` don't apply. |

In the terminal, camera permission belongs to the app you run `mog` from (Terminal, iTerm, Ghostty…).

## Privacy

- **Your profile** is `~/.config/mog/profile.json` (0600). It holds 512 numbers per sample and no images; the numbers can't be turned back into a photo.
- **Intruder photos** are off by default. When on, they go to `~/.config/mog/intruders/` (0700, newest 20 kept) and never leave the Mac. Before swapping in the photo, Mog copies macOS's wallpaper settings, so moving and dynamic wallpapers come back exactly after you unlock.
- **No network.** Mog doesn't connect to anything after the one-time model download during install, except when you click **Check for Updates…** (or run `mog update`). That reads one small file, the Homebrew formula on GitHub, and sends nothing but the request itself.
- **No keylogging.** The typing rule reads the system's "seconds since last key press" counter. Mog never sees which keys you press.

The intruder photo feature takes pictures of people without asking them. That can be illegal where you live, or against your employer's rules on a work laptop, so check before you turn it on.

## Limits

Mog is an extra layer, not a security boundary.

- **No liveness check.** A photo or video of you held up to the camera will probably pass as you.
- **Conditions matter.** Very dim light, strong side angles or a mask can cause misses.
- **Blind spots.** The typing rule can't tell who is typing. It locks on any touch the camera doesn't see a face for, so if you often look away while typing, or work out of the camera's view (lid closed, docked), turn it off.
- **Lock call.** Mog uses a private macOS function (`SACLockScreenImmediate`). It's fine for a personal tool and would not pass App Store review.

Keep your password, FileVault and normal auto-lock on.

## Build from source

```bash
git clone https://github.com/c4rb0nx1/mog && cd mog
./Scripts/fetch-model.sh     # 110 MB model, SHA-256 checked, compiled locally
swift build -c release       # CLI: .build/release/mog
./Scripts/build-app.sh       # app: .build/Mog.app, model included
swift run MogChecks          # 444 checks covering lock rules, matching, alignment, storage
```

| Directory | Contents |
|---|---|
| `Sources/MogCore` | Pure logic: lock rules, matching, alignment math, profile storage. |
| `Sources/MogEngine` | Camera, Vision landmarks, Core ML, screen lock, intruder photo, app installer. The CLI and the app share it. |
| `Sources/mog` | Command-line tool. |
| `Sources/MogBar` | Menu-bar app. |
| `Assets` | App icon. Regenerate with `./Scripts/make-icons.sh`. |

## Credits

- Face model: [ArcFace LResNet100E-IR](https://github.com/onnx/models/tree/main/validated/vision/body_analysis/arcface) from the ONNX Model Zoo, in a Core ML conversion by [RuiSumida](https://huggingface.co/RuiSumida/ArcFace-R100-CoreML). Both Apache-2.0.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
