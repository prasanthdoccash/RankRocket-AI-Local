import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let channelName = "rankrocket/device"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RankRocketDevice") else {
      return
    }
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "getStableDeviceId":
        result(self.stableDeviceId())
      case "getDeviceModel":
        result(self.deviceModel())
      case "getOsVersion":
        result(UIDevice.current.systemVersion)
      case "getAppVersion":
        result(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func stableDeviceId() -> String {
    let service = "com.portableai.portableAiFlutter"
    let account = "stable-device-id"
    if let existing = Self.keychainRead(service: service, account: account) {
      return existing
    }
    let newId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    if Self.keychainWrite(service: service, account: account, value: newId) {
      return newId
    }
    return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
  }

  private func deviceModel() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafePointer(to: &systemInfo.machine) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "" }
    }
    return "\(UIDevice.current.model) (\(machine))"
  }

  private static func keychainWrite(service: String, account: String, value: String) -> Bool {
    let data = Data(value.utf8)
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(deleteQuery as CFDictionary)
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data,
    ]
    return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
  }

  private static func keychainRead(service: String, account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else {
      return nil
    }
    return value
  }
}
