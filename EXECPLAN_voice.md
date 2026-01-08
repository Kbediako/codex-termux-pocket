# Fix Termux voice wake reliability and latency

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept current. If PLANS.md exists in this repo, this plan follows it.


## Purpose / Big Picture

Make the hands‑free Codex voice assistant in Termux feel snappy and reliable. The wake word should trigger quickly without yelling, notifications should reflect the actual wake phrase, and only one listener process should run at a time.


## Progress

- [x] (2026-01-07 02:05) Capture baseline state: processes, logs, wake behavior.
- [x] (2026-01-07 02:05) Fix single‑instance enforcement and wake phrase consistency.
- [x] (2026-01-07 02:07) Implement low‑latency wake detection path and tune thresholds.
- [x] (2026-01-07 02:37) Reset to a single listener process and clean restart.
- [x] (2026-01-07 02:38) Boost wake capture (2s), increase gain, add wake prompt + lower no‑speech threshold, enable debug toast by default.
- [x] (2026-01-07 02:43) Switch wake phrase to “yo yo” with updated matching/stripping logic.
- [x] (2026-01-07 02:46) Enable faster mode defaults: 1s wake capture, lower min bytes, no “Listening” TTS, shorter pre‑record delay.
- [x] (2026-01-07 02:50) Try direct opus for whisper and set mic rate/channels to 16k mono.
- [x] (2026-01-07 02:54) Revert default to wav conversion after direct‑opus decode errors; keep opus as optional override with fallback.
- [x] (2026-01-07 02:58) Accept single “yo/you” token as wake (low‑speech) and strip variants.
- [x] (2026-01-07 03:01) Switch command engine to Android STT (fast, online); raise wake gain and lower wake threshold/min‑bytes.
- [x] (2026-01-07 03:06) Reduce false wakes: raise no‑speech threshold, increase min‑bytes, add low‑energy single‑token filter, add AU English wake prompt.
- [x] (2026-01-07 03:10) Switch wake to Android STT and require double “yo” for wake to avoid false “you” on silence.
- [x] (2026-01-07 04:04) Revert wake to whisper (STT errors), require double “yo” by default, increase wake window to 2s, raise no‑speech threshold.
- [x] (2026-01-07 02:58) Expand wake detection to accept “yo/you/u/oh” variants mapping to “yo yo”.
- [x] (2026-01-07 02:39) Add token-based wake matching and accept "decks" as a wake variant.
- [ ] (2026-01-07 02:39) Validate: one process, fast wake, successful command loop.


## Surprises & Discoveries

- Observation: Multiple `codex-voice` processes exist simultaneously, causing slow or missed wake detection.
  Evidence: `pgrep -af "/codex-voice([[:space:]]|$)"` showed three PIDs.
- Observation: `termux-speech-to-text` can block longer than 5–6 seconds in background use, making it unreliable for wake.
  Evidence: `timeout 6 termux-speech-to-text` exited with 124 (timeout).
- Observation: Recent whisper wake transcripts show mostly noise words (“buzzing”, “inaudible”), even when “codex” is spoken.
  Evidence: `tail -n 200 ~/.codex/device/voice_debug.log`.


## Decision Log

- Decision: Use a deterministic single‑instance guard and avoid concurrent listeners.
  Rationale: Competing listeners fight for the microphone and create unpredictable latency.
  Date/Author: 2026-01-07 / Codex
- Decision: Default wake engine to whisper tiny with short (1s) capture windows.
  Rationale: Android STT blocks in background; whisper tiny provides predictable latency.
  Date/Author: 2026-01-07 / Codex
- Decision: Revert wake engine to whisper and bias recognition toward “codex.”
  Rationale: STT timeouts are too frequent; prompt + lower no‑speech threshold improves wake capture on quiet speech.
  Date/Author: 2026-01-07 / Codex
- Decision: Increase wake capture length to 2s and default gain to 6.0 with debug toasts on.
  Rationale: Current transcripts show noise; longer capture + gain improves signal; debug toasts reveal actual transcript.
  Date/Author: 2026-01-07 / Codex
- Decision: Switch wake detection to token-based matching and add "decks" (whisper mishearing) as an alias.
  Rationale: Wake transcripts show "decks"; token matching avoids broad substring false positives.
  Date/Author: 2026-01-07 / Codex


## Outcomes & Retrospective

Pending. Will update after validation.


## Context and Orientation

- Primary scripts: `/data/data/com.termux/files/home/bin/codex-voice`, `/data/data/com.termux/files/home/bin/codex-voice-on`, `/data/data/com.termux/files/home/bin/codex-voice-off`.
- Logs: `/data/data/com.termux/files/home/.codex/device/voice_debug.log`.
- Current symptoms: Wake word often doesn’t trigger; recent transcripts look like noise and miss “codex.”
- Constraints: Must run on Android/Termux, offline by default, no lingering background processes.


## Plan of Work

1) Capture baseline: verify how many listeners exist, inspect recent log lines, and verify microphone state.
2) Ensure single instance: hard stop lingering listeners and tighten lock behavior so only one process can run.
3) Make wake path fast and consistent: set the wake phrase in notifications to match actual trigger, tune wake capture durations and thresholds, and choose the fastest reliable wake engine (preferring tiny whisper unless Android STT is both fast and reliable).
4) Validate end‑to‑end: confirm one listener process, fast wake response, and successful command response with no hangs.


## Concrete Steps

- Check listener count and mic status:
  - `pgrep -af "/codex-voice([[:space:]]|$)"`
  - `termux-microphone-record -i`
- Inspect logs:
  - `tail -n 120 ~/.codex/device/voice_debug.log`
- Apply code changes in `~/bin/codex-voice` and `~/bin/codex-voice-on`.
- Restart cleanly:
  - `~/bin/codex-voice-off`
  - `pkill -9 -f "/codex-voice([[:space:]]|$)"`
  - `pkill -9 -f "termux-microphone-record"`
  - `rm -rf ~/.codex/device/voice.lock`
  - `~/bin/codex-voice-on`


## Validation and Acceptance

- Exactly one `codex-voice` process is running.
- Notification text matches the actual wake word.
- Saying “codex” at normal volume triggers “Listening.” within ~1–2 seconds.
- Command is transcribed and response spoken without getting stuck.


## Idempotence and Recovery

- All stop/start steps are safe to repeat. If anything gets stuck, re‑run the clean restart steps above.
- If wake detection regresses, revert to tiny whisper for wake and base for commands via environment overrides.


## Artifacts and Notes

- Log snippet and process list will be recorded here after validation.


## Interfaces and Dependencies

- Termux:API (microphone, speech‑to‑text, notifications, TTS).
- whisper.cpp binary at `~/bin/whisper-cpp` and models in `~/.codex/device/models`.
- Observation: whisper-cpp logs repeated “failed to read audio file … input.opus”, producing empty transcripts.
  Evidence: `tail -n 120 ~/.codex/device/voice_debug.log`.
- Observation: Android STT wake can throw “error in results runner” and timeouts in background, causing noisy output.
  Evidence: user report + `voice_debug.log` shows repeated `speech-to-text timeout`.
