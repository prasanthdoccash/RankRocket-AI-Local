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
