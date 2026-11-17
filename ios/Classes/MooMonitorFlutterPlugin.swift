import Flutter
import UIKit

/// Minimal native bridge: records uncaught Objective-C exceptions to a pending
/// file and replays them to Dart on request. Signal handlers / MetricKit / ANR
/// are TODO (see docs) and must not be claimed as covered.
public class MooMonitorFlutterPlugin: NSObject, FlutterPlugin {
  private static var channel: FlutterMethodChannel?
  private static let lock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let ch = FlutterMethodChannel(name: "moo_monitor/native", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MooMonitorFlutterPlugin(), channel: ch)
    channel = ch
    installUncaughtHandler()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "flushPending" {
      MooMonitorFlutterPlugin.flushPending()
      result(nil)
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  private static func pendingURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?.appendingPathComponent("moo_monitor_native_pending.jsonl")
  }

  private static func append(_ obj: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    guard let url = pendingURL() else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    let line = data + "\n".data(using: .utf8)!
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      try? line.write(to: url)
    }
  }

  static func recordCrash(name: String, message: String) {
    append([
      "kind": "crash",
      "name": name,
      "message": message,
      "source": "native_forward",
    ])
  }

  private static func installUncaughtHandler() {
    NSSetUncaughtExceptionHandler(mooUncaughtExceptionHandler)
  }

  private static func flushPending() {
    lock.lock()
    defer { lock.unlock() }
    guard let url = pendingURL(),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return }
    try? FileManager.default.removeItem(at: url)
    for line in text.split(separator: "\n") {
      guard let data = line.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
      channel?.invokeMethod("captureNative", arguments: obj)
    }
  }
}

/// Top-level C-compatible handler: must not capture context.
private func mooUncaughtExceptionHandler(_ exception: NSException) {
  MooMonitorFlutterPlugin.recordCrash(
    name: exception.name.rawValue,
    message: exception.reason ?? "Native error")
}
