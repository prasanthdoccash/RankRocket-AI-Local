import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/models/license_state.dart';

void main() {
  test('parses trial response', () {
    final info = LicenseInfo.fromJson({
      'status': 'trial',
      'device_code': 'RR2F9K4Q',
      'expires_at': '2026-10-07T00:00:00+00:00',
      'days_left': 29,
      'message': '',
    });
    expect(info.status, LicenseStatus.trial);
    expect(info.deviceCode, 'RR2F9K4Q');
    expect(info.daysLeft, 29);
    expect(info.expiresAt, isNotNull);
  });

  test('maps needs_license and unknown to needsLicense', () {
    for (final s in ['needs_license', 'unknown']) {
      final info = LicenseInfo.fromJson({'status': s});
      expect(info.status, LicenseStatus.needsLicense);
    }
  });

  test('maps active and expired', () {
    expect(LicenseInfo.fromJson({'status': 'active'}).status, LicenseStatus.active);
    expect(LicenseInfo.fromJson({'status': 'expired'}).status, LicenseStatus.expired);
  });
}
