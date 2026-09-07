import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:portable_ai_flutter/models/license_state.dart';
import 'package:portable_ai_flutter/screens/license_screen.dart';
import 'package:portable_ai_flutter/services/license_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('hive_license_screen_test');
    Hive.init(dir.path);
    if (!Hive.isBoxOpen(LicenseService.boxName)) {
      await Hive.openBox(LicenseService.boxName);
    }
  });

  tearDown(() async {
    Get.reset();
    await Hive.box(LicenseService.boxName).clear();
  });

  testWidgets('shows device code and activate button', (tester) async {
    final svc = LicenseService();
    svc.status.value = LicenseStatus.needsLicense;
    svc.info.value = const LicenseInfo(
      status: LicenseStatus.needsLicense,
      deviceCode: 'RR2F9K4Q',
    );
    Get.put(svc);

    await tester.pumpWidget(const GetMaterialApp(home: LicenseScreen()));
    await tester.pump();

    expect(find.text('RR2F9K4Q'), findsOneWidget);
    expect(find.textContaining('rpfinserv24@gmail.com'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Activate'), findsOneWidget);
  });

  testWidgets('shows offline message when offline', (tester) async {
    final svc = LicenseService();
    svc.status.value = LicenseStatus.offline;
    Get.put(svc);

    await tester.pumpWidget(const GetMaterialApp(home: LicenseScreen()));
    await tester.pump();

    expect(find.textContaining('internet'), findsWidgets);
  });
}
