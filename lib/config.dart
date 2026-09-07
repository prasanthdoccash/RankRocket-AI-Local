/// App-wide configuration.
class AppConfig {
  /// License server base URL. Override at build time:
  /// flutter run --dart-define=LICENSE_SERVER_URL=http://192.168.1.10:8900
  static const String licenseServerUrl = String.fromEnvironment(
    'LICENSE_SERVER_URL',
    defaultValue: 'https://ai.rankrocket.online',
  );
}
