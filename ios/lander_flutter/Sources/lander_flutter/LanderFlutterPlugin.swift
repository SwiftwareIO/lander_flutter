import Flutter
import UIKit

/// Native side of lander_flutter on iOS.
///
/// Delivers Universal Links (`NSUserActivity`) and custom scheme URLs to Dart
/// for both app delegate and scene based apps, on cold and warm start, and
/// stores the SDK's small state in Application Support, excluded from backups
/// so it is never restored onto another device.
public final class LanderFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  FlutterSceneLifeCycleDelegate
{
  // Link delivery state. Only touched on the main thread.
  private var initialLinkRequested = false
  private var initialLink: String?
  private var sink: FlutterEventSink?
  private var pending: [String] = []

  private let io = DispatchQueue(label: "link.lander.lander_flutter.storage")
  private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z0-9_]{1,64}$")

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LanderFlutterPlugin()
    let methods = FlutterMethodChannel(
      name: "lander_flutter/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let links = FlutterEventChannel(
      name: "lander_flutter/links", binaryMessenger: registrar.messenger())
    links.setStreamHandler(instance)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  // MARK: Link intake

  private func receive(_ url: URL?) {
    guard let link = url?.absoluteString, !link.isEmpty else { return }
    if !initialLinkRequested && initialLink == nil {
      // Cold start: keep it until Dart asks for the launch link.
      initialLink = link
    } else if let sink = sink {
      sink(link)
    } else {
      pending.append(link)
    }
  }

  private func receive(_ activity: NSUserActivity) {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb else { return }
    receive(activity.webpageURL)
  }

  // MARK: App delegate based apps
  // Every method returns false so other plugins still see the URL.

  public func application(
    _ application: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    receive(url)
    return false
  }

  public func application(
    _ application: UIApplication, continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([Any]) -> Void
  ) -> Bool {
    receive(userActivity)
    return false
  }

  // MARK: Scene based apps

  public func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    // Cold start: the URL arrives here, not through the methods below. If a
    // plugin registered earlier returned true, Flutter passes nil options to
    // the rest, and UIKit offers no other way to read them, so the launch link
    // is not seen (see the troubleshooting docs).
    guard let options = connectionOptions else { return false }
    for activity in options.userActivities { receive(activity) }
    for context in options.urlContexts { receive(context.url) }
    return false
  }

  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    for context in URLContexts { receive(context.url) }
    return false
  }

  public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    receive(userActivity)
    return false
  }

  // MARK: FlutterStreamHandler

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    let queued = pending
    pending.removeAll()
    for link in queued { events(link) }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: Method calls

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getInitialLink":
      initialLinkRequested = true
      result(initialLink)
      initialLink = nil
    case "getPlatformInfo":
      result([
        "platform": "ios",
        "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "0.0.0",
        "osVersion": UIDevice.current.systemVersion,
      ])
    case "getInstallReferrer":
      // Android only.
      result(nil)
    case "storageRead":
      storage(call, result) { file in
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
      }
    case "storageWrite":
      let value = (call.arguments as? [String: Any])?["value"] as? String ?? ""
      storage(call, result) { file in
        try Data(value.utf8).write(to: file, options: .atomic)
        return nil
      }
    case "storageDelete":
      storage(call, result) { file in
        if FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.removeItem(at: file)
        }
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func storage(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult,
    _ op: @escaping (URL) throws -> String?
  ) {
    guard let key = (call.arguments as? [String: Any])?["key"] as? String,
      Self.keyPattern.firstMatch(
        in: key, range: NSRange(key.startIndex..., in: key)) != nil
    else {
      result(FlutterError(code: "invalid_key", message: "Invalid storage key", details: nil))
      return
    }
    io.async {
      do {
        let file = try Self.storageDirectory().appendingPathComponent(key)
        let value = try op(file)
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "storage_error", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private static func storageDirectory() throws -> URL {
    var dir = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("lander_flutter", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    // Checked on every access, not only on creation: the flag can be lost when
    // the directory is restored or migrated, and the install ID must never
    // move to another device.
    if (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try dir.setResourceValues(values)
    }
    return dir
  }
}
