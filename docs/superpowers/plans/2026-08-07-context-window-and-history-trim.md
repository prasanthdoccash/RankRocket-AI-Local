# Configurable Context Window + History Auto-Trim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users choose a 1024/4096/8192 context window (with a RAM-based recommendation) and auto-trim chat history so long chats never overflow the window or get silently truncated.

**Architecture:** A persisted `context_size` Hive setting replaces the hardcoded Android context; a pure, token-aware `ChatContextTrimmer` trims history before each call to `LlmService.generate()`. RAM is read via a small Android method channel and turned into a recommendation by a pure `ContextRecommender`. Settings UI gets a 3-step slider plus an Apply button for the recommendation.

**Tech Stack:** Flutter, GetX, Hive, llamadart 0.6.10 (public `tokenize()`), Android Kotlin MethodChannel.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-context-window-and-history-trim-design.md`.
- Flutter is NOT on PATH. Always use the full path `G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat`.
- Run all commands from: `G:\Python_dev\AI_tools\Android_app\Uncensored-Local-AI-Multiplatform`.
- TDD: write the failing test first, run it (confirm fail), implement, run (confirm pass), commit.
- Commit after each task with the exact message given.
- Only modify the files listed in a task. Never touch package identifiers, app name, or pubspec.
- Python is available for JSON/auxiliary checks; prefer the flutter binary for all Dart work.
- `context_size` Hive default = 4096. Constants used everywhere: trimmer `templateTokensPerMessage = 16`, `templateTokensForSystemPrompt = 16`, `minReserve = 64`; reserve = 25% of context (`contextSize ~/ 4`); recommender thresholds 6 GB and 8 GB.

---

### Task 1: Persist the context window setting

**Files:**
- Modify: `lib/services/chat_storage_service.dart` (after the `defaultMaxTokens` setter, ~line 78)
- Test: `test/chat_storage_service_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `ChatStorageService.contextSize` (`int` getter/setter, Hive key `context_size`, default 4096). Later consumed by `LlmService` (Task 5) and Settings UI (Task 7).

- [ ] **Step 1: Write the failing tests**

Append to `test/chat_storage_service_test.dart` inside `void main()`:

```dart
  test('contextSize defaults to 4096', () async {
    final storage = await ChatStorageService().init();
    expect(storage.contextSize, 4096);
  });

  test('contextSize roundtrips through Hive', () async {
    final storage = await ChatStorageService().init();
    storage.contextSize = 8192;
    final reloaded = await ChatStorageService().init();
    expect(reloaded.contextSize, 8192);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/chat_storage_service_test.dart`
Expected: FAIL — `contextSize` is not defined.

- [ ] **Step 3: Implement**

In `lib/services/chat_storage_service.dart`, directly after the `defaultMaxTokens` setter (`_settingsBox.put('max_tokens', value);`) add:

```dart
  int get contextSize =>
      (_settingsBox.get('context_size', defaultValue: 4096) as num).toInt();

  set contextSize(int value) => _settingsBox.put('context_size', value);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/chat_storage_service_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/chat_storage_service.dart test/chat_storage_service_test.dart
git commit -m "feat: persist context window setting (context_size, default 4096)"
```

---

### Task 2: RAM-based context recommendation (pure logic)

**Files:**
- Create: `lib/services/context_recommender.dart`
- Test: `test/context_recommender_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `ContextRecommender.recommendContextSize(int totalRamBytes) -> int` and `ContextRecommender.formatRamBytes(int totalRamBytes) -> String`. Consumed by Settings UI (Task 7).

- [ ] **Step 1: Write the failing tests**

Create `test/context_recommender_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/context_recommender.dart';

void main() {
  const int gb = 1024 * 1024 * 1024;

  test('recommends 1024 under 6 GB', () {
    expect(ContextRecommender.recommendContextSize(5 * gb), 1024);
    expect(ContextRecommender.recommendContextSize((5 * gb) + (999 * 1024 * 1024)), 1024);
  });

  test('recommends 4096 from exactly 6 GB up to just under 8 GB', () {
    expect(ContextRecommender.recommendContextSize(6 * gb), 4096);
    expect(ContextRecommender.recommendContextSize((7 * gb) + (512 * 1024 * 1024)), 4096);
  });

  test('recommends 8192 at 8 GB and above', () {
    expect(ContextRecommender.recommendContextSize(8 * gb), 8192);
    expect(ContextRecommender.recommendContextSize(12 * gb), 8192);
  });

  test('formats RAM bytes as whole GB', () {
    expect(ContextRecommender.formatRamBytes(8 * gb), '8 GB');
    expect(ContextRecommender.formatRamBytes(12 * gb), '12 GB');
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/context_recommender_test.dart`
Expected: FAIL — library not found.

- [ ] **Step 3: Implement**

Create `lib/services/context_recommender.dart`:

```dart
/// Maps a device's total RAM to a safe context-window recommendation.
class ContextRecommender {
  static const int lowContext = 1024;
  static const int midContext = 4096;
  static const int highContext = 8192;

  static const int _sixGb = 6 * 1024 * 1024 * 1024;
  static const int _eightGb = 8 * 1024 * 1024 * 1024;

  /// < 6 GB -> 1024, 6-7.9 GB -> 4096, >= 8 GB -> 8192.
  static int recommendContextSize(int totalRamBytes) {
    if (totalRamBytes < _sixGb) return lowContext;
    if (totalRamBytes < _eightGb) return midContext;
    return highContext;
  }

  /// Formats raw RAM bytes as a whole-number GB label, e.g. "8 GB".
  static String formatRamBytes(int totalRamBytes) {
    final gb = totalRamBytes / (1024 * 1024 * 1024);
    return '${gb.round()} GB';
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/context_recommender_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/context_recommender.dart test/context_recommender_test.dart
git commit -m "feat: add RAM-based context window recommender"
```

---

### Task 3: Token-aware chat history trimmer

**Files:**
- Create: `lib/services/chat_context_trim.dart`
- Test: `test/chat_context_trim_test.dart`

**Interfaces:**
- Consumes: nothing (token counter is injected).
- Produces: `ChatContextTrimmer.trimHistory({required List<Map<String, String>> messages, required String systemPrompt, required int contextSize, required Future<int> Function(String text) countTokens}) -> Future<List<Map<String, String>>>`. Consumed by `ChatController` (Task 6).

- [ ] **Step 1: Write the failing tests**

Create `test/chat_context_trim_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/chat_context_trim.dart';

// 1 token per character, so message costs are predictable.
Future<int> _count(String text) async => text.length;

Map<String, String> _msg(String role, String content) =>
    {'role': role, 'content': content};

void main() {
  test('keeps all messages when they fit under the budget', () async {
    final messages = [
      _msg('user', 'aa'), // 2 + 16 = 18
      _msg('assistant', 'bb'), // 18
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 100, // reserve 25, budget 75
      countTokens: _count,
    );
    expect(trimmed, hasLength(2));
    expect(trimmed.first['role'], 'user');
    expect(trimmed.last['role'], 'assistant');
  });

  test('drops oldest messages on overflow, keeping newest', () async {
    final messages = [
      _msg('user', 'x' * 30), // 30 + 16 = 46
      _msg('assistant', 'y' * 30), // 46
      _msg('user', 'z' * 5), // 5 + 16 = 21
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 100, // budget 75; 21 + 46 = 67 fits, +46 would exceed
      countTokens: _count,
    );
    expect(trimmed, hasLength(2));
    expect(trimmed.first['content'], 'y' * 30);
    expect(trimmed.last['content'], 'z' * 5);
  });

  test('shrinks the reserve when the system prompt needs the room', () async {
    // contextSize 400 -> normal reserve 100 -> budget 300.
    // systemPrompt 'p'*310 -> cost 310 + 16 = 326 > 300, so the trimmer
    // retries with minReserve (64) -> budget 336; 326 fits.
    // Newest 'z'*5 (21) would push to 347 > 336, so only it is kept.
    final messages = [
      _msg('user', 'x' * 30),
      _msg('assistant', 'y' * 30),
      _msg('user', 'z' * 5),
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: 'p' * 310,
      contextSize: 400,
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
    expect(trimmed.single['content'], 'z' * 5);
  });

  test('counts the system prompt against the budget', () async {
    final messages = [
      _msg('user', 'a' * 30), // 46
      _msg('user', 'b' * 30), // 46
    ];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: 's' * 10, // 10 + 16 = 26
      contextSize: 100, // budget 75; 26 + 46 = 72 fits, +46 would exceed
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
    expect(trimmed.single['content'], 'b' * 30);
  });

  test('returns messages unchanged when a single message cannot fit', () async {
    final messages = [_msg('user', 'x' * 90)]; // 90 + 16 = 106 > any budget
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 100, // max budget even at minReserve is 100 - 64 = 36
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
    expect(trimmed.single['content'], 'x' * 90);
  });

  test('returns empty when there are no messages', () async {
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: const [],
      systemPrompt: '',
      contextSize: 100,
      countTokens: _count,
    );
    expect(trimmed, isEmpty);
  });

  test('returns all messages when contextSize is not positive', () async {
    final messages = [_msg('user', 'anything')];
    final trimmed = await ChatContextTrimmer.trimHistory(
      messages: messages,
      systemPrompt: '',
      contextSize: 0,
      countTokens: _count,
    );
    expect(trimmed, hasLength(1));
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/chat_context_trim_test.dart`
Expected: FAIL — library not found.

- [ ] **Step 3: Implement**

Create `lib/services/chat_context_trim.dart`:

```dart
/// Trims a chat history to fit inside the model's context window, dropping
/// the oldest messages first. Never mutates its inputs.
///
/// Budget: 25% of the window is reserved for the reply; the rest is available
/// for the system prompt + history. Per-message template delimiters are
/// accounted for with a conservative constant.
class ChatContextTrimmer {
  static const int templateTokensPerMessage = 16;
  static const int templateTokensForSystemPrompt = 16;
  static const int minReserve = 64;

  /// Returns up to [messages] newest entries (in original order) that fit
  /// alongside [systemPrompt] within [contextSize].
  static Future<List<Map<String, String>>> trimHistory({
    required List<Map<String, String>> messages,
    required String systemPrompt,
    required int contextSize,
    required Future<int> Function(String text) countTokens,
  }) async {
    if (contextSize <= 0) return List.of(messages);
    if (messages.isEmpty) return const [];

    final systemCost = systemPrompt.trim().isEmpty
        ? 0
        : await countTokens(systemPrompt) + templateTokensForSystemPrompt;

    final costs = <int>[];
    for (final m in messages) {
      final content = m['content'] ?? '';
      costs.add(content.isEmpty ? 0 : await countTokens(content) + templateTokensPerMessage);
    }

    var reserve = contextSize ~/ 4;
    if (reserve > contextSize) reserve = contextSize;
    var budget = contextSize - reserve;
    if (systemCost > budget) {
      // System prompt alone needs more prompt room: shrink the reserve to its
      // minimum and retry.
      budget = contextSize - minReserve;
      if (systemCost > budget) {
        return List.of(messages); // pathological; surface the error as-is
      }
    }

    final kept = <Map<String, String>>[];
    var used = systemCost;
    for (var i = messages.length - 1; i >= 0; i--) {
      final cost = costs[i];
      if (used + cost > budget) {
        if (kept.isEmpty) kept.insert(0, messages[i]); // always keep newest
        break;
      }
      used += cost;
      kept.insert(0, messages[i]);
    }
    return kept;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/chat_context_trim_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/services/chat_context_trim.dart test/chat_context_trim_test.dart
git commit -m "feat: add token-aware chat history trimmer"
```

---

### Task 4: Android RAM detection

**Files:**
- Modify: `android/app/src/main/kotlin/com/portableai/portable_ai_flutter/MainActivity.kt`
- Create: `lib/services/device_info_service.dart`
- Test: `test/device_info_service_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `DeviceInfoService().getTotalRamBytes() -> Future<int?>` (null when unavailable). Consumed by Settings UI (Task 7).

- [ ] **Step 1: Write the failing tests**

Create `test/device_info_service_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/device_info_service.dart';

void main() {
  const channel = MethodChannel('rankrocket/device');

  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('returns total RAM in bytes when the platform reports it', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getTotalRam');
      return 8 * 1024 * 1024 * 1024;
    });

    final ram = await DeviceInfoService().getTotalRamBytes();
    expect(ram, 8 * 1024 * 1024 * 1024);
  });

  test('returns null when the platform throws an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'RAM_UNAVAILABLE');
    });

    final ram = await DeviceInfoService().getTotalRamBytes();
    expect(ram, isNull);
  });

  test('returns null when the platform has no implementation', () async {
    final ram = await DeviceInfoService().getTotalRamBytes();
    expect(ram, isNull);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/device_info_service_test.dart`
Expected: FAIL — library not found.

- [ ] **Step 3: Implement the Dart service**

Create `lib/services/device_info_service.dart`:

```dart
import 'package:flutter/services.dart';

/// Reads device capabilities exposed by the Android host.
class DeviceInfoService {
  static const MethodChannel _channel = MethodChannel('rankrocket/device');

  /// Total physical RAM in bytes, or null when unavailable (non-Android).
  Future<int?> getTotalRamBytes() async {
    try {
      return await _channel.invokeMethod<int>('getTotalRam');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
```

- [ ] **Step 4: Implement the Android host channel**

Replace the entire contents of `android/app/src/main/kotlin/com/portableai/portable_ai_flutter/MainActivity.kt` with:

```kotlin
package com.portableai.portable_ai_flutter

import android.app.ActivityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rankrocket/device",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getTotalRam") {
                try {
                    val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                    result.success(am.memoryInfo.totalMem)
                } catch (e: Exception) {
                    result.error("RAM_UNAVAILABLE", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/device_info_service_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/kotlin/com/portableai/portable_ai_flutter/MainActivity.kt lib/services/device_info_service.dart test/device_info_service_test.dart
git commit -m "feat: read device RAM via Android method channel"
```

---

### Task 5: Use the setting in LlmService + expose token counting

**Files:**
- Modify: `lib/services/llm_service.dart` (load block ~lines 149-180; add getter near other getters ~line 31; add countTokens near generate)

**Interfaces:**
- Consumes: `ChatStorageService.contextSize` (Task 1).
- Produces: `LlmService.contextSize` (`int` getter, 0 when nothing loaded) and `LlmService.countTokens(String text) -> Future<int>`. Consumed by `ChatController` (Task 6).

- [ ] **Step 1: Add a failing test to pin the countTokens contract (throws before load)**

`countTokens` needs a real engine to work, so its pre-load contract is pinned with a lightweight test file instead. Create `test/llm_service_contract_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/llm_service.dart';

void main() {
  test('contextSize is 0 when no model is loaded', () {
    final llm = LlmService();
    expect(llm.contextSize, 0);
  });

  test('countTokens throws a StateError when no model is loaded', () async {
    final llm = LlmService();
    await expectLater(
      llm.countTokens('hello'),
      throwsA(isA<StateError>()),
    );
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/llm_service_contract_test.dart`
Expected: FAIL — `contextSize` / `countTokens` not defined.

- [ ] **Step 3: Implement**

In `lib/services/llm_service.dart`:

1. Add a private field next to `StreamSubscription? _generateSub;` (line 29):

```dart
  int _contextSize = 0;
```

2. Add the getter after `publicModelId` (line 47):

```dart
  /// The model's context window in tokens (0 until a model is loaded).
  int get contextSize => _contextSize;
```

3. Replace the hardcoded context block in `loadModel` (currently lines 149-155):

```dart
      // Context window is user-configurable (default 4096). Larger windows
      // consume more KV-cache RAM; the Settings recommendation is based on
      // the device's total RAM.
      final storage = Get.find<ChatStorageService>();
      final contextSize = storage.contextSize;
      _contextSize = contextSize;
```

4. Delete the now-duplicate `final storage = Get.find<ChatStorageService>();` that followed the old context block (it is now declared just above).

5. Add `countTokens` after `generateChatCompletion`'s closing brace (end of the class, before the final `}` of the class):

```dart
  /// Tokenize [text] with the loaded model's tokenizer.
  Future<int> countTokens(String text) async {
    final engine = _engine;
    if (engine == null || !isLoaded.value) {
      throw StateError('No model loaded. Call loadModel() first.');
    }
    return (await engine.tokenize(text, addSpecial: false)).length;
  }
```

- [ ] **Step 4: Run the tests to verify they pass + analyze**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/llm_service_contract_test.dart`
Expected: PASS (2 tests).

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" analyze`
Expected: 0 errors (pre-existing info-level lints ok).

- [ ] **Step 5: Commit**

```bash
git add lib/services/llm_service.dart test/llm_service_contract_test.dart
git commit -m "feat: use configurable context size and expose token counting"
```

---

### Task 6: Trim history in ChatController

**Files:**
- Modify: `lib/controllers/chat_controller.dart` (imports + `sendMessage`, lines 94-116)
- Test: `test/chat_controller_trim_test.dart`

**Interfaces:**
- Consumes: `ChatContextTrimmer.trimHistory` (Task 3), `LlmService.contextSize` + `LlmService.countTokens` (Task 5).
- Produces: nothing new — `sendMessage` now sends a trimmed history.

- [ ] **Step 1: Write the failing tests**

Create `test/chat_controller_trim_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:portable_ai_flutter/controllers/chat_controller.dart';
import 'package:portable_ai_flutter/models/chat_model.dart';
import 'package:portable_ai_flutter/models/message_model.dart';
import 'package:portable_ai_flutter/services/chat_storage_service.dart';
import 'package:portable_ai_flutter/services/llm_service.dart';

class _FakeLlmService extends LlmService {
  List<Map<String, String>>? lastMessages;

  @override
  int get contextSize => 100;

  @override
  Future<int> countTokens(String text) async => text.length;

  @override
  Stream<String> generate({
    required List<Map<String, String>> messages,
    String? systemPrompt,
    double temperature = 0.7,
    int maxTokens = 1024,
  }) async* {
    lastMessages = messages;
  }
}

class _FakeStorage extends ChatStorageService {
  @override
  Future<void> saveChat(ChatModel chat) async {}

  @override
  List<ChatModel> getAllChats() => [];
}

void main() {
  setUp(() {
    Get.put<LlmService>(_FakeLlmService());
    Get.put<ChatStorageService>(_FakeStorage());
  });

  tearDown(() => Get.reset());

  test('sendMessage trims history to fit the context window', () async {
    final llm = Get.find<LlmService>() as _FakeLlmService;
    final ctrl = ChatController();

    final chat = ChatModel(id: '1', systemPrompt: '');
    chat.messages.addAll([
      MessageModel(role: MessageRole.user, content: 'x' * 30), // 46 tokens
      MessageModel(role: MessageRole.assistant, content: 'y' * 30), // 46
      MessageModel(role: MessageRole.user, content: 'z' * 5), // 21
    ]);
    ctrl.chats.add(chat);
    ctrl.activeChatId.value = chat.id;

    await ctrl.sendMessage('hello'); // newest user message, 21 tokens

    // contextSize 100 -> budget 75. System prompt empty.
    // Newest -> oldest: 'hello' 21, 'z'*5 21 (total 42), 'y'*30 would
    // reach 88 > 75, so it and anything older are dropped.
    expect(llm.lastMessages, hasLength(2));
    expect(llm.lastMessages![0]['content'], 'z' * 5);
    expect(llm.lastMessages![0]['role'], 'user');
    expect(llm.lastMessages![1]['content'], 'hello');
    expect(llm.lastMessages![1]['role'], 'user');
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/chat_controller_trim_test.dart`
Expected: FAIL — the fake receives the full 4-message history, not the trimmed 2.

- [ ] **Step 3: Implement**

In `lib/controllers/chat_controller.dart`:

1. Add import at the top (after the existing service imports):

```dart
import '../services/chat_context_trim.dart';
```

2. Replace the history build + generate call (current lines 94-116) with:

```dart
    // Build message history for LLM
    final history = chat.messages
        .where((m) => !m.isSystem)
        .map((m) => m.toLlamaMessage())
        .toList();

    final effectiveSystemPrompt = chat.systemPrompt.isNotEmpty
        ? chat.systemPrompt
        : systemPrompt.value;

    // Trim history to the context window so long chats never overflow.
    final trimmed = _llm.contextSize > 0
        ? await ChatContextTrimmer.trimHistory(
            messages: history,
            systemPrompt: effectiveSystemPrompt,
            contextSize: _llm.contextSize,
            countTokens: (t) => _llm.countTokens(t),
          )
        : history;

    // Start generation
    isGenerating.value = true;
    streamedResponse.value = '';

    final aiMsg = MessageModel(role: MessageRole.assistant, content: '');
    chat.messages.add(aiMsg);
    chats.refresh();

    try {
      final stream = _llm.generate(
        messages: trimmed,
        systemPrompt: effectiveSystemPrompt,
        temperature: temperature.value,
        maxTokens: maxTokens.value,
      );
```

(No other changes to `sendMessage`.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test test/chat_controller_trim_test.dart`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/controllers/chat_controller.dart test/chat_controller_trim_test.dart
git commit -m "feat: auto-trim chat history before generation"
```

---

### Task 7: Settings UI — context slider + RAM recommendation

**Files:**
- Modify: `lib/screens/settings_screen.dart` (imports; `_HardwareSettingsCardState`)

**Interfaces:**
- Consumes: `ChatStorageService.contextSize` (Task 1), `ContextRecommender` (Task 2), `DeviceInfoService` (Task 4).
- Produces: nothing new.

- [ ] **Step 1: Add imports**

In `lib/screens/settings_screen.dart`, add after the existing service imports (line 12):

```dart
import '../services/context_recommender.dart';
import '../services/device_info_service.dart';
```

- [ ] **Step 2: Add state and helpers**

In `class _HardwareSettingsCardState`:

1. Add fields next to `bool _showManual = false;` (line 851):

```dart
  static const List<int> _contextOptions = [1024, 4096, 8192];

  late int _contextSize;
  int? _recommendedContext;
  String? _ramLabel;
```

2. In `initState` (line 887), set the initial value and load the recommendation:

```dart
    _contextSize = _contextOptions.contains(widget.storage.contextSize)
        ? widget.storage.contextSize
        : 4096;
    _loadRecommendation();
```

3. Add these methods to the State class (e.g., after `_saveGpuLayers`):

```dart
  Future<void> _loadRecommendation() async {
    final ram = await DeviceInfoService().getTotalRamBytes();
    if (ram == null) return;
    setState(() {
      _recommendedContext = ContextRecommender.recommendContextSize(ram);
      _ramLabel = ContextRecommender.formatRamBytes(ram);
    });
  }

  void _saveContext(int value) {
    setState(() => _contextSize = value);
    widget.storage.contextSize = value;
  }

  void _applyRecommendedContext() {
    final rec = _recommendedContext;
    if (rec == null) return;
    _saveContext(rec);
    Get.snackbar(
      'Context Applied',
      'Context window set to $rec tokens. Reload the model to apply.',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }
```

- [ ] **Step 3: Add the UI block**

In `build`, insert this block right before the `// ── Manual Override Toggle ──` comment (line 1008), after the auto-config info container:

```dart
          const SizedBox(height: 16),

          // ── Context Window ──
          Row(
            children: [
              Icon(Icons.memory_rounded, size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                'Context Window',
                style: TextStyle(color: context.text, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Tokens the model remembers. Larger windows use more RAM. Applies after reloading the model.',
            style: TextStyle(color: context.textM, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: AppColors.accent,
                    inactiveTrackColor: context.border,
                    thumbColor: AppColors.accent,
                    overlayColor: AppColors.accent.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: _contextOptions.indexOf(_contextSize).toDouble(),
                    min: 0,
                    max: 2,
                    divisions: 2,
                    onChanged: (v) => _saveContext(_contextOptions[v.round()]),
                  ),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  _contextSize.toString(),
                  style: TextStyle(color: context.text, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final opt in _contextOptions)
                  Text(
                    opt.toString(),
                    style: TextStyle(color: context.textD, fontSize: 11),
                  ),
              ],
            ),
          ),
          if (_recommendedContext != null && _ramLabel != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recommended: $_recommendedContext ($_ramLabel RAM)',
                    style: TextStyle(color: context.textM, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _applyRecommendedContext,
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                  label: const Text('Apply'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.text,
                    side: BorderSide(color: context.border),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
```

- [ ] **Step 4: Verify with analyze**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" analyze`
Expected: 0 errors, 0 warnings (pre-existing info lints ok).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/settings_screen.dart
git commit -m "feat: add context window slider and RAM-based recommendation to Settings"
```

---

### Task 8: Full verification

**Files:**
- Modify: none.

- [ ] **Step 1: Run the full test suite**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" test`
Expected: All tests pass EXCEPT the known pre-existing failure `init starts the localhost server by default` (approved to leave). New suites must all pass: chat_storage (4), context_recommender (4), chat_context_trim (7), device_info_service (3), llm_service_contract (2), chat_controller_trim (1).

- [ ] **Step 2: Run static analysis**

Run: `& "G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat" analyze`
Expected: 0 errors; 0 warnings; only pre-existing info lints (incl. `unreachable_switch_default` in `model_library_screen.dart`).

- [ ] **Step 3: Confirm integration points**

Run: `Select-String -Path "lib\**\*.dart" -Pattern "contextSize","countTokens","ChatContextTrimmer","rankrocket/device" -ErrorAction SilentlyContinue`
Expected: matches in `llm_service.dart`, `chat_controller.dart`, `chat_storage_service.dart`, `settings_screen.dart`, `device_info_service.dart`.

- [ ] **Step 4: Commit if anything changed (none expected)**

```bash
git status
```
Expected: clean working tree.
