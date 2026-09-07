import 'dart:convert';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/license_state.dart';
import 'device_info_service.dart';

/// Validates the install's trial/license against the license server.
class LicenseService extends GetxService {
  LicenseService({http.Client? client}) : _client = client ?? http.Client();

  static const String boxName = 'license';
  final http.Client _client;

  final status = LicenseStatus.loading.obs;
  final info = Rxn<LicenseInfo>();
  final activating = false.obs;
  final activateError = ''.obs;

  String? _deviceId;

  Future<void> init({Duration timeout = const Duration(seconds: 8)}) async {
    final box = Hive.box(boxName);
    final devInfo = DeviceInfoService();

    _deviceId = await devInfo.getStableDeviceId();
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = box.get('fallback_device_id') as String?;
      _deviceId ??= _uuid();
      box.put('fallback_device_id', _deviceId);
    }
    box.put('device_id', _deviceId);

    final body = jsonEncode({
      'device_id': _deviceId,
      'platform': devInfo.getPlatform(),
      'model': await devInfo.getDeviceModel(),
      'os_version': await devInfo.getOsVersion(),
      'app_version': await devInfo.getAppVersion(),
    });

    try {
      final res = await _client
          .post(
            Uri.parse('${AppConfig.licenseServerUrl}/api/v1/register'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
      if (res.statusCode == 200) {
        final li = LicenseInfo.fromJson(jsonDecode(res.body));
        info.value = li;
        status.value = li.status;
        box.putAll({
          'status': li.status.name,
          'device_code': li.deviceCode,
          'expires_at': li.expiresAt?.toIso8601String(),
        });
        return;
      }
    } catch (_) {
      // Server unreachable — fall back to cached state below.
    }

    _loadFromCache(box);
  }

  void _loadFromCache(Box box) {
    final cached = box.get('status') as String?;
    if (cached == null) {
      status.value = LicenseStatus.offline;
      return;
    }
    final expiryStr = box.get('expires_at') as String?;
    DateTime? expiry;
    if (expiryStr != null) {
      expiry = DateTime.tryParse(expiryStr);
    }
    if (expiry != null && expiry.isAfter(DateTime.now().toUtc())) {
      final cachedStatus = LicenseStatus.values
          .firstWhere((s) => s.name == cached, orElse: () => LicenseStatus.trial);
      final effective =
          cachedStatus == LicenseStatus.active ? LicenseStatus.active : LicenseStatus.trial;
      status.value = effective;
      info.value = LicenseInfo(
        status: effective,
        deviceCode: box.get('device_code') as String?,
        expiresAt: expiry,
      );
    } else {
      status.value = LicenseStatus.offline;
    }
  }

  Future<void> activate(String key) async {
    activating.value = true;
    activateError.value = '';
    try {
      final res = await _client
          .post(
            Uri.parse('${AppConfig.licenseServerUrl}/api/v1/activate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'device_id': _deviceId, 'license_key': key}),
          )
          .timeout(const Duration(seconds: 10));
      try {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (res.statusCode == 200) {
          final li = LicenseInfo.fromJson(json);
          info.value = li;
          status.value = LicenseStatus.active;
          Hive.box(boxName).putAll({
            'status': 'active',
            'device_code': li.deviceCode,
            'expires_at': li.expiresAt?.toIso8601String(),
          });
        } else {
          activateError.value = (json['error'] as String?) ?? 'Activation failed';
          status.value = LicenseStatus.needsLicense;
        }
      } catch (_) {
        activateError.value = 'Activation failed (unexpected server response).';
      }
    } catch (_) {
      activateError.value =
          'Cannot reach the server. Check your internet connection and try again.';
    } finally {
      activating.value = false;
    }
  }

  String _uuid() {
    // RFC-4122 v4-ish; good enough for a fallback persisted per-install.
    final r = _randomHex(32);
    return '${r.substring(0, 8)}-${r.substring(8, 12)}-4${r.substring(13, 16)}'
        '-a${r.substring(17, 20)}-${r.substring(20, 32)}';
  }

  String _randomHex(int bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write((0 + (DateTime.now().microsecondsSinceEpoch % 16)).toRadixString(16));
    }
    return sb.toString();
  }

  @override
  void onClose() {
    _client.close();
    super.onClose();
  }
}
