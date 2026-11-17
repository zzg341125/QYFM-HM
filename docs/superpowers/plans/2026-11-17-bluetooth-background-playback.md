# Bluetooth Background Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent three-device Bluetooth profiles, device-specific auto-play, call pause/resume, and retain HarmonyOS background playback with a minimal metadata-free AVSession.

**Architecture:** Keep playback and Bluetooth monitoring in the existing `RadioController`. Add a pure Bluetooth-binding model for persistence and matching, extend `BluetoothResumeManager` to report connected device names, and keep a metadata-free AVSession so background audio is not suspended.

**Tech Stack:** HarmonyOS NEXT, ArkTS/ArkUI, `@kit.ConnectivityKit`, `@kit.AudioKit`, `@kit.BackgroundTasksKit`, Hvigor, Node test runner.

**Spec:** `docs/superpowers/specs/2026-11-17-bluetooth-background-playback-design.md`

## Global Constraints

- Store at most 3 Bluetooth devices.
- Device auto-play ignores the resume-window duration.
- Do not publish artwork or media metadata to AVSession; keep only the minimal background-playback session.
- Keep the system-required background continuous-task notification.
- A normally installed app cannot revive after force-stop, system kill, or first install without OS auto-start permission.
- Keep existing user data and backup compatibility.
- Do not add enterprise/system/root-only permissions.

## Review Focus

- Reconnecting an already stored device must preserve its `autoPlay` choice.
- A new device defaults to `autoPlay=false`; the global switch only gates whether enabled device profiles may start playback.
- Adding a fourth device must not evict a saved record; deleting a chosen record immediately replaces it with the pending device.
- A non-auto-play device must not start playback merely because it reconnects.
- User-manual pause must not be overridden by call-end resume.
- Keep only the minimal AVSession creation, activation, playback-state and command handling required for background audio.

---

### Task 1: Bluetooth Binding Model

**Files:**
- Create: `entry/src/main/ets/utils/BluetoothBindings.ts`
- Test: `tests/bluetooth-bindings.test.ts`

**Interfaces:**
- Produces: `BluetoothBinding { deviceId: string; deviceName: string; autoPlay: boolean; lastConnectedAt: number }`
- Produces: `rememberBluetoothBinding(bindings: BluetoothBinding[], deviceId: string, deviceName: string, now: number): BluetoothBinding[]`
- Produces: `findBluetoothBinding(bindings: BluetoothBinding[], deviceId: string): BluetoothBinding | undefined`
- Produces: `replaceBluetoothBinding(bindings: BluetoothBinding[], deviceIdToForget: string, replacement: BluetoothBinding | undefined): BluetoothBinding[]`

- [x] **Step 1: Write failing tests**

Assert that a new device is added, an existing device keeps `autoPlay` while updating its name/time, a fourth device does not evict saved records, and deleting a chosen record replaces it with the pending device.

- [x] **Step 2: Run `node --test tests\bluetooth-bindings.test.ts` and verify the module is missing**

- [x] **Step 3: Implement the pure functions with a strict 3-record limit, explicit deletion and newest-first ordering**

- [x] **Step 4: Re-run the focused test and verify all assertions pass**

- [x] **Step 5: Commit the model and test**

### Task 2: Persist Bluetooth Bindings

**Files:**
- Modify: `entry/src/main/ets/models/Station.ets`
- Modify: `entry/src/main/ets/data/StationRepository.ets`
- Modify: `entry/src/main/ets/utils/QyfmBackupArchive.ts`
- Modify: `tests/qyfm-backup-archive.test.ts`

**Interfaces:**
- Consumes: `BluetoothBinding` from Task 1.
- Produces: `AppSettings.bluetoothBindings: BluetoothBinding[]`.
- Produces: settings backup/restore support without storing WebDAV passwords.

**Steps:**
- [x] **Step 1: Add failing tests for default/migrated empty bindings and ZIP round-trip of three bindings and their toggles.**
- [x] **Step 2: Run the focused tests and verify the new property is absent.**
- [x] **Step 3: Add `bluetoothBindings` to `AppSettings`, `PortableSettings`, defaults, copies, old-settings migration, and `settings.properties` serialization/parsing.**
- [x] **Step 4: Run the focused tests and verify pass.**
- [x] **Step 5: Commit settings persistence.**

### Task 3: Per-Device Bluetooth Auto-Play

**Files:**
- Modify: `entry/src/main/ets/services/BluetoothResumeManager.ets`
- Modify: `entry/src/main/ets/services/RadioController.ets`
- Modify: `entry/src/main/ets/utils/PlaybackRecovery.ts`
- Modify: `tests/playback-recovery.test.ts`

**Interfaces:**
- Consumes: `rememberBluetoothBinding`, `findBluetoothBinding`.
- Changes callback: `onBluetoothConnected(deviceId: string, deviceName: string): void`.
- Produces: `shouldStartBoundBluetoothPlayback(masterEnabled: boolean, deviceAutoPlay: boolean, isPlaying: boolean, buffering: boolean, hasStation: boolean): boolean`.

**Steps:**
- [x] **Step 1: Add a failing test proving a matched `autoPlay=true` device starts after any elapsed time, while `autoPlay=false` does not.**
- [x] **Step 2: Run the focused test and verify it fails.**
- [x] **Step 3: Read A2DP device names with `connection.getRemoteDeviceName`, update bindings on every connection, and start playback before legacy resume-window logic.**
- [x] **Step 4: Expose changed bindings through `RadioSnapshot`; persist them from `Index` without modifying unrelated settings.**
- [x] **Step 5: Run focused tests and commit.**

### Task 4: Minimal AVSession for Background Playback

**Files:**
- Modify: `entry/src/main/ets/services/RadioController.ets`
- Modify: `entry/src/main/ets/utils/PlaybackRecovery.ts`
- Modify: `tests/playback-recovery.test.ts`

**Interfaces:**
- Produces: an active `audio` AVSession without title or artwork metadata while playing.
- Preserves: background playback, media commands, continuous audio background task and AudioInterrupt handling.

**Steps:**
- [x] **Step 1: Replace the old card policy test with session activation/deactivation coverage.**
- [x] **Step 2: Run and verify failure.**
- [x] **Step 3: Keep minimal session activation and playback-state updates without media metadata.**
- [x] **Step 4: Run tests and ArkTS compile; verify background audio and lock-screen behavior on the device.**
- [x] **Step 5: Commit the minimal-session fix.**

### Task 5: Bluetooth Settings UI and Auto-Start Diagnostics

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`
- Modify: `entry/src/main/ets/services/RadioController.ets`

**Interfaces:**
- Consumes: `settings.bluetoothBindings`.
- Produces: three visible slots, each showing name/ID and an independent auto-play toggle.
- Produces: system auto-start support/status text using `autoStartupManager`.

**Steps:**
- [x] **Step 1: Add the UI and event handler for toggling one device’s `autoPlay`.**
- [x] **Step 2: Save settings and call `radio.applySettings` immediately.**
- [x] **Step 3: Show up to three remembered devices, with empty slots when fewer exist.**
- [x] **Step 4: Add auto-start support/status diagnostics and manual system-setting guidance.**
- [x] **Step 5: Build and device-check the settings page.**
- [x] **Step 6: Commit UI work.**

### Task 6: Device Verification and Release

**Files:**
- Version files for `1.0.43`.

**Steps:**
- [x] **Step 1: Run the full Node test suite.**
- [x] **Step 2: Build signed HAP and APP in `F:\codex\qyfm-harmony`.**
- [x] **Step 3: Install on `5XM0226114020541` and verify version `1.0.43 / 1000043`.**
- [x] **Step 4: Verify background and lock-screen playback with the metadata-free AVSession, and confirm Bluetooth binding persistence.**
- [x] **Step 5: Verify call-interrupt pause/resume policy with unit tests and code review.**
- [ ] **Step 6: Verify a real incoming call on the device; this requires an external call and is not automatable from the current environment.**
- [ ] **Step 7: Commit, tag, push, and publish GitHub release assets.**

## Execution Ledger

- Final review: self-review (no subagent tool)
