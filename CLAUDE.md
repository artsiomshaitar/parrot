# parrot

macOS push-to-talk dictation daemon. Single Swift binary, on-device Whisper via
WhisperKit, text injected at the cursor.

## Conventions

**Comments.** Don't add them unless they are genuinely necessary, and keep them
short. Code should explain itself; a comment earns its place only when it
records something the code cannot — a measured constant, a platform trap, a
decision that looks wrong until you know why. Never narrate what the next line
does.

**Commits.** Do not add Claude, or any AI tool, as a co-author or in the commit
message. Write the message as the author.

## Layout

- `Sources/parrot/Audio/` — capture, device state
- `Sources/parrot/Transcription/` — WhisperKit, vocabulary, phonetic matching
- `Sources/parrot/Input/` — hotkey tap, text injection
- `Sources/parrot/UI/` — menu bar, overlay
- `Tests/ParrotTests/` — unit tests

## Commands

```sh
swift build -c release --arch arm64
swift test
./scripts/dev.sh          # install as `parrot-dev` beside the release copy
./scripts/dev.sh --run
```

## Notes

The vocabulary is matched phonetically; thresholds in `PhoneticMatcher` were
measured against a corpus, so change them with evidence rather than intuition.

`--debug-mic` logs microphone acquire/release and Bluetooth codec switches;
`mic-probe` measures them directly.
