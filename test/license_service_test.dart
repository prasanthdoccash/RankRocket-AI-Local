import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portable_ai_flutter/models/license_state.dart';
import 'package:portable_ai_flutter/services/license_service.dart';

Future<http.Response> _json(int code, Map<String, dynamic> body) async =>
    http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('hive_license_test');
    Hive.init(dir.path);
    if (!Hive.isBoxOpen(LicenseService.boxName)) {
      await Hive.openBox(LicenseService.boxName);
    }
    const channel = MethodChannel('rankrocket/device');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStableDeviceId') return 'ANDROID_ID_123';
      return null;
    });
  });

  tearDown(() async {
    Get.reset();
    await Hive.box(LicenseService.boxName).clear();
  });

  test('init registers and stores trial status', () async {
    final client = MockClient((req) async {
      expect(req.url.path, '/api/v1/register');
      return _json(200, {
        'status': 'trial',
        'device_code': 'RR2F9K4Q',
        'expires_at': '2026-10-07T00:00:00+00:00',
        'days_left': 29,
        'message': '',
      });
    });

    final svc = LicenseService(client: client);
    await svc.init(timeout: const Duration(seconds: 2));

    expect(svc.status.value, LicenseStatus.trial);
    expect(svc.info.value!.deviceCode, 'RR2F9K4Q');
    expect(Hive.box(LicenseService.boxName).get('status'), 'trial');
  });

  test('falls back to offline when server unreachable and no cache', () async {
    final client = MockClient((req) async => throw Exception('offline'));
    final svc = LicenseService(client: client);
    await svc.init(timeout: const Duration(milliseconds: 500));
    expect(svc.status.value, LicenseStatus.offline);
  });

  test('activate success flips to active', () async {
    final client = MockClient((req) async {
      if (req.url.path == '/api/v1/activate') {
        return _json(200, {
          'status': 'active',
          'expires_at': '2027-09-01T00:00:00+00:00',
          'days_left': 360,
        });
      }
      return _json(500, {'error': 'boom'});
    });
    final svc = LicenseService(client: client);
    await svc.activate('RR-AAAA-BBBB-CCCC');
    expect(svc.status.value, LicenseStatus.active);
    expect(svc.activateError.value, '');
  });

  test('activate failure surfaces server error', () async {
    final client = MockClient(
      (req) async => _json(403, {'error': 'This license key is already used on another device'}),
    );
    final svc = LicenseService(client: client);
    await svc.activate('RR-AAAA-BBBB-CCCC');
    expect(svc.status.value, LicenseStatus.needsLicense);
    expect(svc.activateError.value, 'This license key is already used on another device');
  });
}
