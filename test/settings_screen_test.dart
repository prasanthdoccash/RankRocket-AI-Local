import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:portable_ai_flutter/bindings/app_bindings.dart';
import 'package:portable_ai_flutter/models/chat_model.dart';
import 'package:portable_ai_flutter/models/message_model.dart';
import 'package:portable_ai_flutter/screens/settings_screen.dart';
import 'package:portable_ai_flutter/services/chat_storage_service.dart';
import 'package:portable_ai_flutter/services/model_manager.dart';
import 'package:portable_ai_flutter/theme/app_theme.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    tempDir = await Directory.systemTemp.createTemp('settings-widget-test-');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(ChatModelAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(MessageRoleAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(MessageModelAdapter());
    await Hive.openBox<ChatModel>('chats');
    await Hive.openBox('settings');
    await Hive.openBox('license');
    Get.testMode = true;
    AppBindings().dependencies();
    await Get.find<ChatStorageService>().init();
    await Get.find<ModelManager>().init();
  });

  tearDown(() async {
    Get.reset();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('settings renders content below global system prompt', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: AppTheme.lightTheme,
        home: const SettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Global System Prompt'), findsOneWidget);

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Generation Settings'),
      500,
      scrollable: scrollable,
    );
    expect(find.text('Generation Settings'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Context Window'),
      500,
      scrollable: scrollable,
    );
    expect(find.text('Context Window'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Hardware Configuration'),
      500,
      scrollable: scrollable,
    );
    expect(find.text('Hardware Configuration'), findsOneWidget);
  });
}
