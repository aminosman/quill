# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

`install` also self-assembles a minimal `~/Applications/Quill.app` around a
copy of the binary — Info.plist, feather icon, codesigned with your Apple
Development identity when one exists — and points the LaunchAgent at it.
The bundle is what lets notifications carry a real icon and gives the
privacy permissions a stable identity that survives rebuilds. The CLI copy
keeps working from wherever you put it.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Or don't click at all: **auto-record** (on by default, toggleable in the menu)
watches for meeting apps and browsers using the microphone and starts a
session by itself — a notification tells you it's rolling. It stops once the
mic has been free for a grace period, then transcribes as usual. Every app's
mic use is logged to stderr (`/tmp/quill.err.log` under the LaunchAgent), so
adding an unlisted app to the watchlist is just reading off its bundle ID.

## Meetings in the menu

The menu lists the **last five meetings**. A red dot on the feather (and on
the meeting row) means a transcript finished and hasn't been looked at yet;
viewing the transcript, opening the folder, or filing the meeting clears it.

**View transcript** opens a viewer window: the conversation as a
speaker-tagged, timestamped list (me in blue, them in orange), with a filter
field, selectable text, project filing from the footer, and a
delete-to-Trash button that also cleans up any project links.

Each meeting's submenu offers **Link to project**: projects are the
subdirectories of `~/Projects` (configurable via `projects_dir`), most
recently used first. Linking symlinks the session folder into
`<project>/meetings/` — created on first use — so transcripts sit next to the
code they're about while the recording itself stays in the recordings root. A
meeting can link to several projects; click again to unlink. All of this is
plain filesystem state: the unread flag is an `.unread` marker in the session
folder, project recency is the `meetings/` directory's mtime.

Not every directory is a meeting project — **Meetingable projects** in the
menu is a checklist of which ones count (`meeting_projects` in config;
everything checked until you save a selection). Only meetingable projects
appear in link menus and can auto-match, which keeps personal folders from
muddying the matcher.

With **auto-file** on (`auto_file`, default on), each finished transcript is
scanned for meetingable project names and filed to **the single best
match**: the project mentioned most, strictly more than any other, at least
twice (whole words, case-insensitive, `-`/`_` read as spaces, names under 4
characters skipped). The notification tells you which case you're in:
**"transcript filed"** names the project and clears the red dot — it's
categorized, nothing left to do; **"transcript needs filing"** means a tie
or only passing mentions — too ambiguous to call, resolve it from the menu;
plain **"transcript ready"** means no project was mentioned at all. In the
ambiguous and no-match cases the red dot stays until you file or read it.

**Auto-discard** (`auto_discard.enabled`, default on) keeps noise out of the
menu: a recording that is both short (`max_seconds`, default 120) and nearly
wordless (`max_words`, default 25) — an accidental trigger, a dropped call —
is moved to the **Trash** (never hard-deleted, always recoverable) instead
of entering the unread/auto-file pipeline.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "auto_record": {
    "enabled": true,
    "apps": ["com.tinyspeck.slackmacgap", "us.zoom.xos"],
    "min_mic_seconds": 3,
    "stop_grace_seconds": 20
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `projects_dir` — whose subdirectories are the linkable projects (default
  `~/Projects`); also settable from the menu via *Choose projects folder…*.
- `auto_file` — scan finished transcripts for project-name mentions and file
  each to its single best-matching project automatically (default on).
- `meeting_projects` — the meetingable allowlist, managed from the menu;
  absent = every project directory is eligible.
- `transcription.enabled` — set `false` to just record.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `auto_record.enabled` — start/stop recordings automatically when a watched
  app uses the mic (default on; also toggleable from the menu bar).
- `auto_record.apps` — bundle-ID prefixes to watch. Defaults cover Slack,
  Zoom, Teams, FaceTime, Discord, and the major browsers; helper processes
  (`com.google.Chrome.helper`) match their parent. Note browsers grab the mic
  for more than meetings — voice search and mic-permission prompts shorter
  than `min_mic_seconds` are filtered, but a long dictation session will
  trigger a recording.
- `auto_record.min_mic_seconds` — how long the mic must be held before
  recording starts (default 3).
- `auto_record.stop_grace_seconds` — how long the mic must stay free before
  an auto-started recording stops (default 20), so a dropped-and-rejoined
  call stays one session. Manually started recordings never auto-stop.
- `auto_record.split_silence_seconds` — back-to-back meetings often share
  one mic grab (browsers hold the mic between calls), which the idle
  detector can't see. If both tracks stay silent this long (default 45,
  0 disables) during an auto session, the next sound is treated as a new
  meeting: the old recording stops and transcribes, a fresh one starts.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
