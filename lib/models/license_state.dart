/// Lifecycle of the app license/trial on this device.
enum LicenseStatus {
  loading,
  trial,
  active,
  expired,
  needsLicense,
  offline,
  serverError,
}

/// Parsed result from the license server.
class LicenseInfo {
  final LicenseStatus status;
  final String? deviceCode;
  final DateTime? expiresAt;
  final int daysLeft;
  final String? message;

  const LicenseInfo({
    required this.status,
    this.deviceCode,
    this.expiresAt,
    this.daysLeft = 0,
    this.message,
  });

  factory LicenseInfo.fromJson(Map<String, dynamic> json) {
    final raw = (json['status'] as String?) ?? 'needs_license';
    final status = switch (raw) {
      'trial' => LicenseStatus.trial,
      'active' => LicenseStatus.active,
      'expired' => LicenseStatus.expired,
      _ => LicenseStatus.needsLicense,
    };
    return LicenseInfo(
      status: status,
      deviceCode: json['device_code'] as String?,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
      daysLeft: (json['days_left'] as num?)?.toInt() ?? 0,
      message: json['message'] as String?,
    );
  }
}
