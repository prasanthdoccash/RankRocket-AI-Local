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
