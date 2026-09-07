import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads device capabilities + stable device ID from the native host.
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

  /// Stable ID that survives app uninstall/reinstall:
  /// Android -> Settings.Secure.ANDROID_ID, iOS -> Keychain-persisted UUID.
  Future<String?> getStableDeviceId() async {
    try {
      return await _channel.invokeMethod<String>('getStableDeviceId');
    } catch (_) {
      return null;
    }
  }

  Future<String?> getDeviceModel() async {
    try {
      return await _channel.invokeMethod<String>('getDeviceModel');
    } catch (_) {
      return null;
    }
  }

  Future<String?> getOsVersion() async {
    try {
      return await _channel.invokeMethod<String>('getOsVersion');
    } catch (_) {
      return null;
    }
  }

  Future<String?> getAppVersion() async {
    try {
      return await _channel.invokeMethod<String>('getAppVersion');
    } catch (_) {
      return null;
    }
  }

  String getPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'desktop';
    }
  }
}
