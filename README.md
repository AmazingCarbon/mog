# Mog

Locks your Mac when someone else looks at it while you're away. Runs fully offline, on Apple Silicon Macs (macOS 14+).

## Install

```bash
brew install c4rb0nx1/tap/mog
mog install-app          # optional: the menu-bar app, into ~/Applications
```

The formula builds from source with the Xcode Command Line Tools and downloads the ~110 MB face model once. The model is pinned by checksum and compiled locally.

## How it works

1. **Detect**: Apple Vision finds every face in the frame, with eye and mouth landmarks.
2. **Align**: each face is rotated and scaled onto a standard 112×112 layout, so the eyes and mouth always land in the same place.
3. **Identify**: ArcFace, a dedicated face-recognition network, turns the aligned face into 512 numbers and compares them with your enrolled samples (cosine similarity):
   - **0.40 or higher** is you.
   - **Below 0.33** is someone else.
   - **In between** is "unsure" and never starts a countdown. That band covers you at awkward angles.

   Live test with the owner and two friends: owner 0.40–0.98, friends −0.03–0.32.
4. **Decide** (`Sources/MogCore/Guard.swift`):
   - Nobody in view → nothing happens. Walking away never locks.
   - You in view → nothing happens, even if someone is looking over your shoulder.
   - A stranger without you, continuously for 1 s (at least 3 camera frames) → lock. One-frame flickers don't reset the countdown, and a couple of stray misreads can't lock.
   - After locking, Mog turns itself off. You re-arm it yourself, so it can't lock you out in a loop.

Your profile (`~/.config/mog/profile.json`, 0600) holds only the 512-number vectors, no images.

## Build from source

```bash
./Scripts/fetch-model.sh     # one-time: ~110 MB model, SHA-256 checked, compiled locally
swift build -c release
./Scripts/build-app.sh       # optional: .build/Mog.app with the model inside
```

Model: ArcFace LResNet100E-IR from the ONNX Model Zoo (Apache-2.0), in a Core ML conversion from Hugging Face `RuiSumida/ArcFace-R100-CoreML`, pinned by commit and checksum. See `NOTICE`.

## Use

### Menu-bar app

`mog install-app` (Homebrew) or `./Scripts/build-app.sh` (from source), then open Mog.

The eye icon in the menu bar is your control:

- **Turn On** before you step away. The guard arms after 3 seconds. The icon fills in.
- A stranger in view without you brings up a red banner at the top of the screen with a countdown. It clears if you come back or they leave.
- After it locks, Mog is **off**. Turn it on again when you leave next time. It never re-arms itself.
- **Enroll My Face…** opens a live camera window with a progress bar. It uses the same profile as the CLI.
- **Show Intruder Photo on Lock Screen** (off by default): the frame that triggered the lock is saved and set as your wallpaper, so it's what the lock screen shows. After you unlock, your own wallpaper comes back. **Open Intruder Photos** shows the saved ones (newest 20 kept).

The app asks for its own camera permission the first time. The permission is separate from your terminal's.

### CLI

```bash
mog status        # camera permission, lock service, model, profile
mog probe         # 8 s check: does it see and align your face?
mog enroll        # sit alone, look at the screen, move your head slightly
mog test          # dry run: logs OWNER / STRANGER 0.xx per frame, NEVER locks
mog lock-test     # locks the screen in 3 s, checks the lock path
mog watch         # the real thing: locks once, then exits
mog watch --photo # same, and shows the intruder's photo on the lock screen
mog intruders     # list saved intruder photos
```

From a source build, the binary is `.build/release/mog`.

### Intruder photos

They live in `~/.config/mog/intruders/` (0700, files 0600, newest 20 kept) and never leave the Mac. macOS has no public way to change only the lock-screen picture, so Mog sets the photo as the wallpaper just before locking; the lock screen uses the wallpaper. Your original is recorded in `~/.config/mog/wallpaper-backup.json` and put back after unlock, when Mog next starts, or with `mog restore-wallpaper`.

It photographs whoever sits at your Mac. Taking pictures of people without their knowledge can be illegal where you live or against workplace policy, so check before turning it on, especially on a work laptop.

Camera permission belongs to the app you run it from (Terminal, iTerm, Ghostty…).

Tuning: `--grace 3` waits longer before locking. `--stranger 0.28` needs more certainty before calling someone a stranger, giving fewer false alarms but a lookalike could slip by. `--threshold 0.45` is stricter about who counts as you.

## Limits

This is not a security boundary. A photo or video of you held up to the camera will likely pass as you (no liveness check). Poor light, strong side angles, or someone wearing a mask can cause misses. Your macOS password, FileVault, and auto-lock stay your real protection. The lock call is a private macOS API (`SACLockScreenImmediate`), fine for personal use and not suitable for the App Store.

## Layout

- `Sources/MogCore`: pure logic (lock rules, matching, alignment math, profile). Covered by `swift run MogChecks`, 63 checks, including a replay of live test scores.
- `Sources/MogEngine`: camera, Vision landmarks, Core ML embedding, screen lock, intruder photo, app installer, plus the watch and enroll sessions that the CLI and the app both run.
- `Sources/mog`: CLI.
- `Sources/MogBar`: menu-bar app.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
