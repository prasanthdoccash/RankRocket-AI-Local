import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/device_info_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns stable device id from platform channel', () async {
    const channel = MethodChannel('rankrocket/device');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStableDeviceId') return 'ANDROID_ID_123';
      if (call.method == 'getDeviceModel') return 'Pixel 8';
      if (call.method == 'getOsVersion') return '14';
      if (call.method == 'getAppVersion') return '1.1.0';
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final svc = DeviceInfoService();
    expect(await svc.getStableDeviceId(), 'ANDROID_ID_123');
    expect(await svc.getDeviceModel(), 'Pixel 8');
    expect(await svc.getOsVersion(), '14');
    expect(await svc.getAppVersion(), '1.1.0');
  });
}
