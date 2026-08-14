# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

Fork of [digimata/parrot](https://github.com/digimata/parrot) by Andrew Jones — the original is his, and it's a nice piece of work. I added a configurable push-to-talk key, a vocabulary file for terms Whisper keeps mishearing, and menu bar settings so you don't have to pass flags every time.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/artsiomshaitar/parrot/master/scripts/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
parrot vocab test "the post hawk API"  # try the vocabulary without talking
parrot vocab show                      # list loaded terms and their sound keys
```

## Vocabulary

Whisper has no idea how your stack is spelled. It hears "PostHog" and writes
"Post Hawk", "post hogg", "Post-Hog" — a different way each time.

Put the term in `~/.config/parrot/vocab.txt`, one per line:

```
PostHog
Kubernetes
TypeScript
```

Terms are matched by **sound**, not spelling, so one line covers every
mangling — including the ones you haven't seen yet. "post hawk", "kuber netes"
and "type script" all land correctly without a rule for each.

Two guards keep it honest: a phrase has to both sound like the term *and* be
spelled close to it, and a single ordinary English word is never rewritten. So
"the cores are hot" doesn't become "the CORS are hot", and "I called the car
dealer" survives intact. Measured on 7,950 lines of English prose: two changes,
both correct.

When a mishearing isn't phonetically close to the term — "my sequel" for MySQL
— use an exact rule instead. These run first and always win:

```
my sequel => MySQL
```

The menu bar has a **Dictionary…** item showing what's loaded (`Dictionary… (61 terms, 3 rules)`). Clicking it opens the file in your editor — and saving takes effect immediately, no restart.

Check your file against real sentences without dictating:

```sh
parrot vocab test "let's look at the post hawk dashboard"   # → ... PostHog dashboard
parrot vocab test --explain "kuber netes"                   # shows key + score
pbpaste | parrot vocab test --changed-only                  # audit a whole document
```

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
