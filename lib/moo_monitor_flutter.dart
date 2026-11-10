library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'src/client.dart';
import 'src/config.dart';
import 'src/redactor.dart';
import 'src/store.dart';

export 'src/config.dart';

/// Root-isolate facade. An empty token never touches disk, hooks or the network.
class MooMonitor {
  MooMonitor._();
  static MonitorClient? _client;
  static Future<bool>? _installing;
  static FlutterExceptionHandler? _previousFlutter, _flutterHook;
  static ErrorCallback? _previousPlatform, _platformHook;
  static _Lifecycle? _lifecycle;
  static final _isolates = <Isolate, RawReceivePort>{};
  static bool get installed => _client?.active ?? false;
  static bool get disabled => _client?.disabled ?? false;

  static Future<bool> install(MonitorConfig config,
      {Directory? directory, bool installHandlers = true}) {
    if (_client != null) return Future.value(installed);
    return _installing ??= _install(config, directory, installHandlers)
        .whenComplete(() => _installing = null);
  }

  static Future<bool> _install(
      MonitorConfig config, Directory? directory, bool hooks) async {
    if (!config.enabled) return false;
    try {
      final base = directory ??
          Directory(
              '${(await getApplicationSupportDirectory()).path}/moo_monitor_flutter');
      final store = EventStore(base,
          maxRecords: config.maxRecords, maxBytes: config.maxBytes);
      if (!store.readable) return false;
      _client = MonitorClient(config, store);
      if (!installed) return false;
      if (hooks) {
        _previousFlutter = FlutterError.onError;
        _flutterHook = (details) {
          capture(details.exception, details.stack ?? StackTrace.empty,
              message: 'Flutter framework error', source: 'flutter_framework');
          if (_previousFlutter != null) {
            _previousFlutter!(details);
          } else {
            FlutterError.presentError(details);
          }
        };
        FlutterError.onError = _flutterHook;
        _previousPlatform = PlatformDispatcher.instance.onError;
        _platformHook = (error, stack) {
          capture(error, stack,
              message: 'Unhandled Dart error', source: 'root_isolate');
          return _previousPlatform?.call(error, stack) ?? false;
        };
        PlatformDispatcher.instance.onError = _platformHook;
      }
      _lifecycle = _Lifecycle();
      WidgetsBinding.instance.addObserver(_lifecycle!);
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null) _lifecycle!.didChangeAppLifecycleState(state);
      return true;
    } catch (_) {
      _restoreHooks();
      _client?.close();
      _client = null;
      return false;
    }
  }

  static void capture(Object error, StackTrace stack,
      {String? message,
      String source = 'capture',
      Map<String, Object?> extras = const {}}) {
    _client?.capture(error, stack,
        message: message, source: source, extras: extras);
  }

  static void screen(String name) => _client?.screen(name);
  static Future<void> flush() async {
    await _client?.flush();
  }

  /// Register before resuming a paused child isolate; remove before closing its port.
  static void observeIsolate(Isolate isolate) {
    if (!installed || _isolates.containsKey(isolate)) return;
    final port = RawReceivePort((dynamic value) {
      if (value is! List || value.length != 2 || value[0] is! String) return;
      capture(value[0] as String,
          StackTrace.fromString(value[1] is String ? value[1] as String : ''),
          message: 'Child isolate error', source: 'child_isolate');
    });
    try {
      isolate.addErrorListener(port.sendPort);
      _isolates[isolate] = port;
    } catch (_) {
      port.close();
    }
  }

  static void stopObservingIsolate(Isolate isolate) {
    final port = _isolates.remove(isolate);
    if (port == null) return;
    try {
      isolate.removeErrorListener(port.sendPort);
    } catch (_) {/* already gone */}
    port.close();
  }

  static Future<void> close() async {
    await _installing;
    for (final isolate in _isolates.keys.toList()) {
      stopObservingIsolate(isolate);
    }
    _restoreHooks();
    _client?.close();
    _client = null;
  }

  static void _restoreHooks() {
    if (identical(FlutterError.onError, _flutterHook) && _flutterHook != null) {
      FlutterError.onError = _previousFlutter;
    }
    if (identical(PlatformDispatcher.instance.onError, _platformHook) &&
        _platformHook != null) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
    if (_lifecycle != null) {
      try {
        WidgetsBinding.instance.removeObserver(_lifecycle!);
      } catch (_) {/* binding may not have been initialized */}
    }
    _lifecycle = null;
    _previousFlutter = _flutterHook = null;
    _previousPlatform = _platformHook = null;
  }
}

class _Lifecycle extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) MooMonitor._client?.lifecycle(true);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      MooMonitor._client?.lifecycle(false);
    }
  }

  @override
  void didHaveMemoryPressure() => MooMonitor._client?.memoryWarning();
}

/// The host resolves routes to fixed code identifiers. Route arguments are never read.
class MonitorNavigatorObserver extends NavigatorObserver {
  MonitorNavigatorObserver({required this.screenName});
  final String? Function(Route<dynamic> route) screenName;
  Route<dynamic>? _top;
  void _screen(Route<dynamic>? route) {
    if (route == null) return;
    try {
      final name = screenName(route);
      if (name != null && Redactor.screen(name) != null) {
        MooMonitor.screen(name);
      }
    } catch (_) {/* monitoring must not affect navigation */}
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _top = route;
    _screen(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, _top)) {
      _top = previousRoute;
      _screen(previousRoute);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(oldRoute, _top)) {
      _top = newRoute;
      _screen(newRoute);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Removing a route below the visible one does not change the current screen.
    if (identical(route, _top)) {
      _top = previousRoute;
      _screen(previousRoute);
    }
  }
}
