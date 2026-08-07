# Design: Configurable context window + RAM-based recommendation + history auto-trim

Date: 2026-08-07
Status: Approved

## Problem

Android chat generation is hard-limited to `n_ctx = 1024` tokens (`lib/services/llm_service.dart:152`, deliberate anti-OOM choice), while the Llama 3.2 3B model actually supports up to 128K context. Two failure modes result:

1. **Silently truncated replies.** The full prompt is re-tokenized every turn with no history management (`lib/controllers/chat_controller.dart:95-98`). Generation breaks when `currentPos >= nCtx` (llamadart `llama_cpp_service.dart:3338`), producing "incomplete" assistant messages.
2. **Hard crash on continuation.** Once accumulated history exceeds the window, llamadart throws `"Tokenization failed or prompt too long"` (llamadart `llama_cpp_service.dart:3080`) and the app writes it into the chat (`chat_controller.dart:126`).

Both predate the maxTokens feature and persist regardless of the max output length setting.

## Goals

- Let users choose a context window (1024 / 4096 / 8192) that matches their device.
- Recommend a context window based on the device's total RAM, with an Apply button.
- Make long chats work by auto-trimming old history so the prompt never exceeds the window, and reserving output headroom so replies are not cut off.
- Fix "Tokenization failed or prompt too long" for good.

## Non-goals

- Summarization of old history.
- Modifying stored chat history (only what is sent to the model is trimmed).
- Changing the Local API server message path (`generateChatCompletion` in `local_api_server_service.dart`).
- RAM detection on iOS/desktop (Android-only; recommendation hidden elsewhere).
- Changing the maxTokens slider range.

## Architecture

### 1. Context window setting (persists, applies at model load)

- **`ChatStorageService`** (`lib/services/chat_storage_service.dart`):
  - Add `int get contextSize` / `set contextSize(int value)` backed by Hive key `context_size`, default **4096**. Mirror the `defaultMaxTokens` pattern (safe `as num` cast + `.toInt()`).
- **`LlmService`** (`lib/services/llm_service.dart`):
  - In `loadModel`, replace the hardcoded `contextSize = Platform.isAndroid ? 1024 : 2048` with `final contextSize = storage.contextSize;`.
  - Store the resolved context size in a field `_contextSize` and expose `int get contextSize` (returns 0 when no model loaded).
  - Update the load log line to use the field.
- **Effect timing:** `n_ctx` is fixed at model load time. Changing the setting takes effect on the next model load. The UI communicates this.

### 2. RAM detection (Android)

- **`MainActivity.kt`** (`android/app/src/main/kotlin/com/portableai/portable_ai_flutter/MainActivity.kt`):
  - Add `configureFlutterEngine(flutterEngine: FlutterEngine)` override.
  - Register `MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rankrocket/device")`.
  - Handle method `getTotalRam`: return `(getSystemService(ACTIVITY_SERVICE) as ActivityManager).memoryInfo.totalMem` (a Long, bytes) via `result.success(...)`.
  - Any failure → `result.error(...)`.
- **`lib/services/device_info_service.dart`** (new):
  - `Future<int?> getTotalRamBytes()`: calls the channel; returns the Long as int, or `null` on `MissingPluginException`/platform error. On non-Android, returns `null`.

### 3. Recommendation logic (pure, testable)

- **`lib/services/context_recommender.dart`** (new):
  - `int recommendContextSize(int totalRamBytes)`: `< 6 GB → 1024`, `6 GB ≤ ram < 8 GB → 4096`, `≥ 8 GB → 8192`.
  - `String formatRamBytes(int totalRamBytes)`: e.g. `"8 GB"`.
  - Pure Dart; no platform dependencies.

### 4. Settings UI — Hardware Configuration

**File:** `lib/screens/settings_screen.dart`, inside `_HardwareSettingsCardState`.

- Add a "Context Window" row with a **3-step slider** (steps `[1024, 4096, 8192]`, `divisions: 2`), matching the existing temperature/max-token slider style. Slider index ↔ value via the ordered list.
- The slider's current value is the persisted `storage.contextSize`; `onChanged` persists immediately via `widget.storage.contextSize = ...`.
- **Recommendation block** (loaded once in `initState` via `DeviceInfoService`):
  - If RAM is available, show `Recommended: <recommended> (<formatted RAM>)` plus an **Apply** `OutlinedButton` that sets the slider + persists `storage.contextSize` to the recommended value, then shows a `Get.snackbar`.
  - If RAM unavailable, hide the recommendation block.
- Helper caption under the card content: "Context window applies after reloading the model."

### 5. Token-aware auto-trim

- **`lib/services/chat_context_trim.dart`** (new): pure logic, dependencies injected.
  - Public API: `class ChatContextTrimmer` with a static method:
    ```dart
    static Future<List<Map<String, String>>> trimHistory({
      required List<Map<String, String>> messages, // full history (no system prompt)
      required String systemPrompt,
      required int contextSize,
      required Future<int> Function(String text) countTokens,
    })
    ```
  - Constants: `templateTokensPerMessage = 16`, `templateTokensForSystemPrompt = 16`, `minReserve = 64`.
  - Budget: `reserve = contextSize ~/ 4`; `promptBudget = contextSize - reserve`.
  - Count system prompt tokens as `countTokens(systemPrompt) + templateTokensForSystemPrompt` (0 if empty).
  - Count each message as `countTokens(content) + templateTokensPerMessage`.
  - Walk messages newest → oldest, always include the newest, accumulate until adding another message would exceed `promptBudget`; drop the rest.
  - Return kept messages in original (chronological) order.
  - **Fallback:** if the newest message + system prompt already exceed `promptBudget`, retry with `reserve = minReserve` (more prompt room). If it still doesn't fit, return the messages unchanged (llamadart surfaces the error as today — a pathological single message).
  - `trimHistory` never mutates its inputs.

### 6. Token counting + wiring

- **`LlmService`**:
  - Add `Future<int> countTokens(String text)` → `_engine!.tokenize(text, addSpecial: false).length`. Throws `StateError('No model loaded...')` when `_engine == null`.
- **`ChatController.sendMessage`** (`lib/controllers/chat_controller.dart`):
  - After building `history` (current lines 95-98), trim:
    ```dart
    final trimmed = _llm.contextSize > 0
        ? await ChatContextTrimmer.trimHistory(
            messages: history,
            systemPrompt: effectiveSystemPrompt,
            contextSize: _llm.contextSize,
            countTokens: (t) => _llm.countTokens(t),
          )
        : history;
    ```
  - Pass `trimmed` to `_llm.generate(...)`.
  - `effectiveSystemPrompt` is the same expression used today for `systemPrompt:` (chat's own prompt, else global).

## Data flow

User sends message → full history built → trimmed to ≤ (contextSize − 25%) tokens → `generate()` → replies get the 25% headroom (not cut off at the window edge) → next turn's prompt always fits → "Tokenization failed or prompt too long" is eliminated.

## Testing

- **`test/context_recommender_test.dart`** (new): thresholds and boundary cases (< 6 GB, exactly 6 GB, 6–7.9 GB, exactly 8 GB, ≥ 8 GB); `formatRamBytes`.
- **`test/chat_context_trim_test.dart`** (new): fake `countTokens` (no engine needed):
  - returns all messages when they fit;
  - drops oldest on overflow;
  - always keeps the newest message;
  - preserves order of kept messages;
  - counts the system prompt against the budget;
  - stops exactly at the budget boundary (adds while `≤ promptBudget`, never exceeds);
  - single-message fallback path.
- **`test/chat_storage_service_test.dart`** (extend): `contextSize` default 4096 + Hive roundtrip.

## Risks

- Raising context increases KV-cache RAM (≈55 MB / 1024 tokens for this 3B model). Mitigated by user choice + RAM-based recommendation. 8192 remains the maximum and is only recommended on ≥ 8 GB devices.
- A user who lowers context below existing history relies on trimming (works; stored history intact).
- RAM detection is Android-only; other platforms simply hide the recommendation.
