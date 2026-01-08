# Build Porcupine Wake-Word Android Service + Termux Bridge (Paused)

Status: paused at user request. This document is the planned path when you want Google-level wake speed/quality.

## Goal

Create a lightweight Android foreground service that runs a dedicated wake-word engine (Picovoice Porcupine). On wake, it triggers Termux via RUN_COMMAND to capture and execute a spoken command. This separates fast, always-on wake detection from slower ASR.

## Why

Google-style wake performance requires a tiny always-on wake model. Whisper is excellent for transcription but not optimized for continuous wake detection. Porcupine is designed for low-latency on-device wake.

## Inputs Needed From You

- Picovoice AccessKey (required to use Porcupine SDK).
- Wake phrase choice:
  - Built-in Porcupine keyword (fastest setup).
  - Custom keyword model (.ppn) from Picovoice Console for “hey codex”.
- OK to install Android build tooling on-device (Java/Gradle/SDK; large download).

## Planned Architecture

- Android app (foreground service) using Porcupine Android SDK.
- On wake: send RUN_COMMAND intent to Termux.
- Termux script handles STT command + Codex response.

## Planned Steps

1) Install build tooling in Termux:
   - OpenJDK, Gradle, Android SDK command-line tools.
2) Clone Porcupine repo and start from their `porcupine-demo-service` Android example.
3) Add Termux RUN_COMMAND intent wiring:
   - Request `com.termux.permission.RUN_COMMAND`.
   - Send intent with `com.termux.RUN_COMMAND` and command path.
4) Add wake keyword:
   - Built-in keyword or custom `.ppn` in `assets/`.
5) Build APK on-device and install.
6) Create Termux script for command capture + `codex exec`.
7) Validate: wake latency, command accuracy, no background leaks.

## Notes / Constraints

- Termux must allow external apps:
  - `~/.termux/termux.properties` → `allow-external-apps=true` and `termux-reload-settings`.
- Foreground service notification required for always-on microphone.
- For best quality, keep wake engine in app, and use Android STT (online) for commands.

## Success Criteria

- Wake triggers within ~300–700 ms, no false wake while silent.
- Reliable command capture and execution.
- Single persistent service + clean stop/start control.

