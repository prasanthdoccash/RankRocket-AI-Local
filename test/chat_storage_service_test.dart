import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:portable_ai_flutter/models/chat_model.dart';
import 'package:portable_ai_flutter/models/message_model.dart';
import 'package:portable_ai_flutter/services/chat_storage_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('portable-ai-settings-test-');
    Hive.init(tempDir.path);

    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChatModelAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(MessageRoleAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(MessageModelAdapter());
    }

    await Hive.openBox<ChatModel>('chats');
    await Hive.openBox('settings');
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('defaultMaxTokens defaults to 1024', () async {
    final storage = await ChatStorageService().init();
    expect(storage.defaultMaxTokens, 1024);
  });

  test('defaultMaxTokens roundtrips through Hive', () async {
    final storage = await ChatStorageService().init();
    storage.defaultMaxTokens = 2048;
    final reloaded = await ChatStorageService().init();
    expect(reloaded.defaultMaxTokens, 2048);
  });
}
