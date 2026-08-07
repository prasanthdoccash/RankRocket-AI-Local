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
