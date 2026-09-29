<p align="center">
  <img src="Assets/icon-512.png" width="160" alt="Mog app icon">
</p>

<h1 align="center">Mog</h1>

<p align="center">
  <b>Your Mac locks itself when someone else is looking at it.</b><br>
  Face recognition that runs on your Mac. Nothing gets uploaded.
</p>

<p align="center">
  <a href="https://github.com/AmazingCarbon/mog/tags"><img alt="Version" src="https://img.shields.io/github/v/tag/AmazingCarbon/mog?label=version&color=2e5d52"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-2e5d52">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-2e5d52">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-2e5d52"></a>
</p>

---

You get up for coffee and leave your laptop open. Your friend sneaks over to mess with it. About a second later the screen locks, and if you turned on the intruder photo, their face is the lock screen wallpaper when you get back.

Just walking away doesn't lock anything. It only kicks in when someone who isn't you shows up, or when someone starts touching the Mac while nobody's in front of the camera.

## Install

```bash
brew tap c4rb0nx1/tap https://github.com/AmazingCarbon/homebrew-tap
brew install c4rb0nx1/tap/mog
mog install-app
```

Open **Mog** from `~/Applications`, click **Enroll My Face…**, and hit **Turn On** before you walk away.

Homebrew builds it from source, which takes about a minute. It downloads the face model (110 MB) once and checks it against a pinned SHA-256. After that Mog doesn't go online, except when you check for updates.

> On macOS 27 you need the Command Line Tools for Xcode 27, or Homebrew refuses to build. Get them from **System Settings → General → Software Update**.

## Updating

On 0.3.0 or newer, click **Check for Updates…** in the menu bar, or run `mog update`.

On anything older, run this once. After that the menu button works.

```bash
brew update && brew upgrade c4rb0nx1/tap/mog && mog install-app
```

Then quit Mog and open it again. If brew says you're up to date but `mog version` shows an old number, your tap is stuck. Unstick it:

```bash
git -C "$(brew --repository c4rb0nx1/tap)" pull --ff-only
```

## What it does

- **Knows your face.** It uses ArcFace, a real face-recognition model, not a "these two pictures look kind of alike" guess. When I tested it with two friends, I scored 0.40–0.98 and they never got above 0.32.
- **Locks fast.** A stranger in view without you: about 1 second. Turning your own head doesn't count.
- **Catches sneaky hands.** If nobody's in front of the camera and someone types, clicks or touches the trackpad, it locks right away, no countdown. This includes you, so if you look away from the camera while typing, it'll lock on you too. You can switch this off in the menu.
- **Stealth mode.** Keeps the camera (and its green light) off until someone touches the Mac, then takes one quick look. More on this below.
- **You're the boss.** If you're in frame, nothing locks, even with someone reading over your shoulder.
- **Intruder photo** (optional). The person who got caught becomes your lock screen wallpaper. Whoever's closest to the screen stays sharp, and everyone and everything else gets a light blur. Your normal wallpaper comes back when you unlock, including moving and dynamic ones.
- **No lock loops.** After it locks, Mog turns itself off. It never turns back on by itself.
- **Only you can turn it off.** While it's on, Turn Off, Quit, Re-enroll and Forget only work if you're in front of the camera. If anyone else tries, the Mac locks instead.
- **Private.** Your face is saved as 512 numbers per sample, never as a photo. No accounts, no tracking.

## How it works

```text
camera → find faces → line them up → ArcFace → 512 numbers → you / not sure / stranger → lock?
```

1. **Find faces.** Apple's Vision finds every face in the frame, plus the eyes and mouth.
2. **Line them up.** Each face gets rotated and scaled so the eyes and mouth are always in the same spot. That's what ArcFace expects.
3. **Who is it?** ArcFace turns each face into 512 numbers, and Mog compares them with the ones it saved when you enrolled:
   - **0.40 or more:** you.
   - **Under 0.33:** someone else.
   - **In between:** not sure. That never locks, which covers you at weird angles.
4. **Lock or not.** The rules live in `Sources/MogCore/Guard.swift`:
   - **Stranger:** someone who isn't you is in view without you for 3 frames, so a single bad frame can't do it. Mog shows a red banner, then locks after 1 second. If you show up, it cancels.
   - **Hands with no face:** someone types, clicks or touches the trackpad while no face is in view. It locks on the next frame, about a quarter of a second later. Typing while a face is in view never counts. Mog only reads *when* the last key press happened, never *which* key, so it doesn't need Input Monitoring permission.

### Stealth mode

You can't turn off the camera's green light; Apple wires it to the camera. So stealth mode just keeps the camera off until someone touches the Mac.

1. **Camera off.** Mog only watches the system's "last input" timers: keys, clicks, the pointer, scrolling, trackpad gestures.
2. **Touch.** The camera turns on. It needs about a second to wake up and see a face.
3. **Who is it?**
   - **You:** the camera goes back off, and Mog trusts you while you keep using the Mac.
   - **Someone else,** 2 frames in a row: locks right away.
   - **Nobody it can recognize** within 2.5 seconds: locks. Someone's using it out of view.
4. **Checking again.** If nobody touches the Mac for 3 seconds, the next touch gets checked again. That way someone who sits down after you leave gets checked instead of trusted. Even if you type nonstop, it checks once a minute. Each check blinks the light.

The catch: someone who only *looks* at the screen without touching anything won't get caught. Turning Mog off also needs a quick look, so the light blinks then. And don't use stealth mode with the lid closed, because the camera can't see you and every first touch will lock.

## The menu bar

Everything's in the eye icon in your menu bar:

- **Turn On / Turn Off.** It starts watching 3 seconds after you turn it on.
- **Dock icon.** While it's on, Mog also shows up in the Dock. Right-click it for Turn Off and Quit, which is handy if the menu bar icon is hidden behind the notch.
- **You have to be there to turn it off.** Turn Off and Quit only work if Mog saw you in the last 2 seconds. Otherwise the Mac locks. Logging out and shutting down always work.
- **Status line.** What Mog sees right now: *You're here (match 0.91)*, *Nobody in view*, or *Stranger in view. Locking in 1 s*.
- **Enroll My Face…** Opens the camera. Look at the screen and move your head a little. Takes about 10 seconds.
- **Show Intruder Photo on Lock Screen.** Off by default. **Open Intruder Photos** shows the saved ones.
- **Lock on Typing When Nobody's There.** On by default. Turn it off if you often type without facing the camera, like with the lid closed and an external keyboard. It's greyed out in stealth mode, which already has this built in.
- **Stealth Mode (Camera Off Until Touched).** Off by default. The eye icon gets a circle around it while stealth is on. Changes kick in the next time you turn Mog on.
- **Check for Updates…** Asks GitHub for the newest version, only when you click it. If there's one, the item changes to *Update Available: 0.x.y…*. **Update in Terminal** then runs the upgrade in Terminal so you can watch, and reopens Mog when it's done. If Mog's on, updating needs you in view, just like quitting.

The first time you turn it on, macOS asks if Mog can use the camera.

## Command line

Everything the app does, plus some debugging tools:

```bash
mog enroll          # save your face (sit alone, look at the screen)
mog test            # practice run: shows OWNER / STRANGER 0.xx for every frame, never locks
mog watch           # the real thing; locks once, then quits
mog watch --photo   # ...and puts the intruder's photo on the lock screen
mog watch --stealth # camera off until the Mac is touched, then one look
mog test --stealth  # practice run of stealth mode, shows how long the check took
mog status          # camera permission, lock, model, your profile
mog probe           # 8 second camera check
mog lock-test       # locks the screen in 3 s, to check locking works
mog intruders       # list saved intruder photos
mog wallpaper-check # swaps in a test picture for 3 s, then puts your wallpaper back
mog update          # check for a new version and upgrade with Homebrew
```

Options:

| Flag | Default | What it does |
|---|---|---|
| `--grace S` | `1` | How many seconds a stranger has to be in view before it locks. |
| `--threshold X` | `0.40` | Match score from which a face counts as you. |
| `--stranger X` | `0.33` | Match score below which a face counts as a stranger. Lower means fewer false alarms, but a lookalike has an easier time. |
| `--no-input-lock` | lock is on | Don't lock when someone touches the Mac with nobody in view. |
| `--stealth` | off | Camera off until someone touches the Mac. `--grace` and `--no-input-lock` don't do anything here. |

In the terminal, camera permission belongs to whatever app you run `mog` in (Terminal, iTerm, Ghostty…).

## Privacy

- **Your face profile** is `~/.config/mog/profile.json`, readable only by you. It's just numbers, 512 per sample, and they can't be turned back into a picture.
- **Intruder photos** are off by default. If you turn them on, they're saved in `~/.config/mog/intruders/`, only the latest 20 are kept, and they never leave your Mac.
- **Network.** After install, Mog only goes online when you click Check for Updates or run `mog update`. That downloads one small file from GitHub, and nothing gets sent.
- **No keylogging.** Mog only knows *when* you last pressed a key, never *what* you pressed.

Heads up: the intruder photo takes pictures of people without asking them. Depending on where you live, or your company's rules on a work laptop, that might not be okay. Check before you turn it on.

## What it can't do

Mog is an extra layer, not real security.

- **It can be fooled by a photo.** Someone holding up a picture or video of you will probably get through.
- **Light and angles matter.** Very dark rooms, looking from the side, or a mask can make it miss.
- **It can't tell whose hands those are.** The typing rule locks on any touch when it can't see a face. If you often look away while typing, or use the Mac with the lid closed, turn that rule off.
- **It uses a hidden macOS function to lock the screen** (`SACLockScreenImmediate`). Fine for a personal tool, but Apple wouldn't allow it in the App Store.

Keep your password, FileVault and normal auto-lock turned on.

## Build it yourself

```bash
git clone https://github.com/AmazingCarbon/mog && cd mog
./Scripts/fetch-model.sh     # downloads the 110 MB model, checks it, compiles it
swift build -c release       # the CLI: .build/release/mog
./Scripts/build-app.sh       # the app: .build/Mog.app, model included
swift run MogChecks          # tests for the lock rules, matching, alignment and storage
```

| Folder | What's in it |
|---|---|
| `Sources/MogCore` | The logic: lock rules, matching, alignment math, saving your profile. |
| `Sources/MogEngine` | Camera, Vision, Core ML, locking, intruder photo, installer. Shared by the CLI and the app. |
| `Sources/mog` | The command-line tool. |
| `Sources/MogBar` | The menu bar app. |
| `Assets` | The app icon. Rebuild it with `./Scripts/make-icons.sh`. |

## Credits

- Face model: [ArcFace LResNet100E-IR](https://github.com/onnx/models/tree/main/validated/vision/body_analysis/arcface) from the ONNX Model Zoo, converted to Core ML by [RuiSumida](https://huggingface.co/RuiSumida/ArcFace-R100-CoreML). Both Apache-2.0.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
