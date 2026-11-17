import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'redactor.dart';
import 'store.dart';
import 'transport.dart';

/// Single source of truth for the SDK version sent in every envelope.
const String sdkVersion = '0.1.0';

String newEventId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final value = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
}

class MonitorClient {
  static final _breadcrumbType = RegExp(r'^[a-z][a-z0-9_]*$');
  static final _breadcrumbName =
      RegExp(r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*){1,5}$');
  MonitorClient(this.config, this.store,
      {MonitorTransport? transport,
      DateTime Function()? now,
      this.memorySnapshot,
      this.automatic = true})
      : now = now ?? DateTime.now,
        transport = transport ??
            IoMonitorTransport(
                Uri.parse(
                    '${config.endpoint.replaceAll(RegExp(r'/+$'), '')}/api/v1/app-errors/intake'),
                config.token) {
    identity = sha256
        .convert(utf8.encode(jsonEncode([
          config.endpoint.replaceAll(RegExp(r'/+$'), ''),
          config.app,
          config.token
        ])))
        .toString();
    disabled = store.readState('disabled')?['identity'] == identity;
    final oldId = store.readState('identity')?['seed'];
    final seed = oldId is String && oldId.isNotEmpty ? oldId : newEventId();
    if (oldId != seed) store.writeState('identity', {'seed': seed});
    installId = sha256.convert(utf8.encode(seed)).toString();
    if (config.detectUncleanExit && active) _reportUncleanExitIfNeeded();
    _persistSession(clean: false);
    if (!disabled && config.enabled) schedule(const Duration(seconds: 10));
  }
  final MonitorConfig config;
  final EventStore store;
  final MonitorTransport transport;
  final DateTime Function() now;
  final bool automatic;
  final Map<String, int> Function()? memorySnapshot;
  late final String identity, installId;
  final String sessionId = newEventId();
  final _uptime = Stopwatch()..start();
  final _breadcrumbs = ListQueue<Map<String, Object>>(30);
  bool disabled = false, _closed = false, _exhausted = false;
  bool _capturing = false;
  bool? _foreground;
  String? _screen;
  int? _lastMemoryWarning;
  int _attempts = 0;
  int? lastStatus;
  String? lastError;
  DateTime? lastSentAt;
  final ListQueue<Map<String, Object>> _memorySamples =
      ListQueue<Map<String, Object>>();
  int _memoryWarnings = 0;
  Timer? _timer;
  int? _timerDueMs;
  Future<void>? _flush;
  bool get active => config.enabled && !disabled && !_closed;

  /// Read-only, business-free counters for host-side triage.
  Map<String, Object?> get diagnostics => <String, Object?>{
        'pending': store.pendingLength,
        'pending_bytes': store.pendingBytes,
        'dropped': store.dropped,
        'disabled': disabled,
        'closed': _closed,
        if (lastStatus != null) 'last_status': lastStatus,
        if (lastError != null) 'last_error': lastError,
        if (lastSentAt != null)
          'last_sent_at': lastSentAt!.toUtc().toIso8601String(),
      };

  static const List<String> _allowedKinds = <String>[
    'crash',
    'anr',
    'hang',
    'low_memory',
    'handled',
    'termination',
    'webview_gone'
  ];

  /// Forward a native-origin event captured by the host/native bridge (MetricKit,
  /// signal handler, Java/NSException). This SDK does not install native handlers;
  /// it only records, bounds and delivers what the native layer reports.
  void captureNative(
      {required String kind,
      required String name,
      String message = 'Native error',
      String source = 'native_forward',
      Map<String, Object?> extras = const {}}) {
    if (!_allowedKinds.contains(kind) || kind == 'low_memory') return;
    capture(const _NativeEvent(), StackTrace.empty,
        message: message,
        source: source,
        kind: kind,
        name: name,
        extras: extras);
  }

  /// Parse an event forwarded by a native plugin over a MethodChannel.
  /// Protocol: method 'captureNative', args {kind, name, message?, source?, extras?}.
  void handleNativeCall(MethodCall call) {
    if (call.method != 'captureNative') return;
    final args = call.arguments;
    if (args is! Map) return;
    final kind = args['kind'];
    final name = args['name'];
    if (kind is! String || name is! String) return;
    final extras = args['extras'];
    captureNative(
        kind: kind,
        name: name,
        message: args['message'] is String
            ? args['message'] as String
            : 'Native error',
        source: args['source'] is String
            ? args['source'] as String
            : 'native_forward',
        extras: extras is Map ? extras.cast<String, Object?>() : const {});
  }

  void bindNativeChannel(MethodChannel channel) {
    channel.setMethodCallHandler((call) async => handleNativeCall(call));
  }

  void capture(Object error, StackTrace stack,
      {String? message,
      String source = 'capture',
      String kind = 'handled',
      String? name,
      Map<String, Object?> extras = const {}}) {
    if (!active || _capturing || !_allowedKinds.contains(kind)) {
      return;
    }
    // toString/StackTrace/custom Map access can synchronously re-enter capture.
    // This root-isolate gate ends before the next attempt; it is not object/hash
    // deduplication, and deliberately emits no diagnostic log on the drop path.
    _capturing = true;
    try {
      final trace = Redactor.scrub(stack.toString(), bytes: 32768);
      String text;
      try {
        text = message ?? error.toString();
      } catch (_) {
        text = 'Error';
      }
      final payload = <String, Object?>{
        'source': Redactor.scrub(source, bytes: 64),
        'runtime': 'flutter',
        'uptime_ms': _uptime.elapsedMilliseconds,
      };
      for (final entry in extras.entries.take(16)) {
        if (!payload.containsKey(entry.key)) payload[entry.key] = entry.value;
      }
      final record = <String, dynamic>{
        'event_id': newEventId(),
        'platform': config.platform,
        'kind': kind,
        'count': 1,
        'occurred_at': now().toUtc().toIso8601String(),
        'release': Redactor.truncate(config.release, 64),
        'build': Redactor.truncate(config.build, 32),
        'env': Redactor.truncate(config.environment, 16),
        'exception': {
          'name':
              Redactor.scrub(name ?? error.runtimeType.toString(), bytes: 192),
          'message': Redactor.scrub(text),
          'stack': trace
        },
        'frames': Redactor.frames(trace, inAppPackages: config.inAppPackages),
        'device': {
          for (final key in [
            'os',
            'os_version',
            'model',
            'manufacturer',
            'abi'
          ])
            if (config.device[key] != null)
              key: Redactor.scrub(config.device[key]!, bytes: 128)
        },
        'context': {
          'install_id': installId,
          'session_id': sessionId,
          if (_screen != null) 'screen': _screen,
          if (_foreground != null) 'foreground': _foreground,
          if (config.symbolId.isNotEmpty)
            'symbol_id': Redactor.truncate(config.symbolId, 64)
        },
        'breadcrumbs':
            _breadcrumbs.map((entry) => Map<String, Object>.of(entry)).toList(),
        'payload': Redactor.payload(payload, dropped: store.dropped),
      };
      // Host getters above may synchronously close this client. Check at the
      // commit boundary too; no other root-isolate task can interleave here.
      if (!active) return;
      store.append(record);
      schedule(const Duration(seconds: 5));
    } catch (_) {
      store.dropped++;
    } finally {
      _capturing = false;
    }
  }

  void screen(String value) {
    if (!active || Redactor.screen(value) == null || value == _screen) return;
    _screen = value;
    _breadcrumb('screen', value);
    _sampleMemory();
    _persistSession(clean: false);
  }

  void lifecycle(bool foreground) {
    if (!active || foreground == _foreground) return;
    _foreground = foreground;
    _breadcrumb('lifecycle', foreground ? 'foreground' : 'background');
    if (foreground) _sampleMemory();
    _persistSession(clean: false);
    _cancelTimer();
    schedule(Duration.zero);
  }

  void memoryWarning() {
    final elapsed = _uptime.elapsedMilliseconds;
    if (!active ||
        (_lastMemoryWarning != null &&
            elapsed - _lastMemoryWarning! < 3600000)) {
      return;
    }
    _lastMemoryWarning = elapsed;
    _memoryWarnings++;
    final metrics = <String, Object?>{};
    // Sample only after throttling. A failed sampler must never suppress the
    // warning or retain application objects during an already pressured moment.
    try {
      final snapshot = memorySnapshot?.call() ?? const <String, int>{};
      for (final key in _memoryKeys) {
        final value = snapshot[key];
        if (value != null && value >= 0) metrics[key] = value;
      }
      _recordMemorySample(elapsed, metrics);
    } catch (_) {/* keep the warning without optional measurements */}
    _persistSession(clean: false);
    capture(const _MemoryWarning(), StackTrace.empty,
        message: 'Memory warning',
        source: 'memory_warning',
        kind: 'low_memory',
        name: 'MemoryWarning',
        extras: <String, Object?>{
          ...metrics,
          'warnings_in_session': _memoryWarnings,
          if (_memorySamples.isNotEmpty)
            'memory_samples':
                _memorySamples.map((e) => Map<String, Object>.of(e)).toList(),
        });
    // The event is a memory warning, never evidence of an OOM process kill.
  }

  static const List<String> _memoryKeys = <String>[
    'image_cache_bytes',
    'image_cache_count',
    'image_cache_live_count',
    'image_cache_pending_count',
    'process_rss_bytes',
    'process_peak_rss_bytes'
  ];

  void _recordMemorySample(int uptimeMs, Map<String, Object?> values) {
    final entry = <String, Object>{'uptime_ms': uptimeMs};
    for (final key in _memoryKeys) {
      final value = values[key];
      if (value is int && value >= 0) entry[key] = value;
    }
    if (entry.length == 1) return; // nothing measurable
    _memorySamples.add(entry);
    final limit = config.memorySampleLimit.clamp(1, 32);
    while (_memorySamples.length > limit) {
      _memorySamples.removeFirst();
    }
  }

  void _sampleMemory() {
    final snapshot = memorySnapshot;
    if (snapshot == null || !config.enabled) return;
    try {
      _recordMemorySample(_uptime.elapsedMilliseconds, snapshot());
    } catch (_) {/* optional measurements must not affect host work */}
  }

  void _persistSession({required bool clean}) {
    if (!config.enabled) return;
    try {
      final rss = _latestRss();
      store.writeState('session', <String, dynamic>{
        'session_id': sessionId,
        'build': config.build,
        'clean': clean,
        'had_memory_warning': _memoryWarnings > 0,
        if (rss != null) 'last_rss': rss,
        if (_screen != null) 'last_screen': _screen,
        if (_foreground != null) 'foreground': _foreground,
        'heartbeat_at': now().toUtc().toIso8601String(),
      });
    } catch (_) {/* state is best-effort diagnostics */}
  }

  int? _latestRss() {
    for (final entry in _memorySamples.toList().reversed) {
      final value = entry['process_rss_bytes'];
      if (value is int) return value;
    }
    return null;
  }

  void _reportUncleanExitIfNeeded() {
    final previous = store.readState('session');
    if (previous == null || previous['clean'] == true) return;
    if (previous['had_memory_warning'] != true) return;
    final previousId = previous['session_id'];
    if (previousId is String && previousId == sessionId) return;
    _memoryWarnings = 0;
    capture(const _UncleanExit(), StackTrace.empty,
        message:
            'Previous session ended without a clean shutdown after a memory warning',
        source: 'session_exit',
        name: 'UncleanExit',
        extras: <String, Object?>{
          if (previous['last_rss'] is int)
            'previous_rss_bytes': previous['last_rss'],
          if (previous['last_screen'] is String)
            'previous_screen': previous['last_screen'],
          if (previous['build'] is String) 'previous_build': previous['build'],
          if (previous['heartbeat_at'] is String)
            'previous_heartbeat_at': previous['heartbeat_at'],
        });
  }

  void _breadcrumb(String type, String name) {
    // Repeated sync requests should not evict the preceding useful transitions.
    if (_breadcrumbs.isNotEmpty &&
        _breadcrumbs.last['type'] == type &&
        _breadcrumbs.last['name'] == name) {
      return;
    }
    _breadcrumbs.add(
        {'t': now().toUtc().toIso8601String(), 'type': type, 'name': name});
    if (_breadcrumbs.length > 30) _breadcrumbs.removeFirst();
  }

  void breadcrumb(String type, String name) {
    if (!active ||
        type.length > 16 ||
        name.length > 64 ||
        _breadcrumbType.stringMatch(type) != type ||
        _breadcrumbName.stringMatch(name) != name ||
        Redactor.scrub(name) != name) {
      return;
    }
    try {
      _breadcrumb(type, name);
    } catch (_) {/* diagnostics cannot affect host work */}
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _timerDueMs = null;
  }

  void schedule(Duration delay) {
    if (!automatic || !active || _exhausted) return;
    final due = now().millisecondsSinceEpoch + delay.inMilliseconds;
    // Keep the earliest deadline instead of ignoring a sooner request.
    final current = _timerDueMs;
    if (_timer != null && current != null && current <= due) return;
    _timer?.cancel();
    _timerDueMs = due;
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      _timerDueMs = null;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    if (_flush != null) return _flush!;
    final completer = Completer<void>();
    _flush = completer.future;
    () async {
      try {
        await _send();
      } catch (_) {
        lastError = 'transport_error';
        if (active) _retry();
      } finally {
        _flush = null;
        completer.complete();
      }
    }();
    return completer.future;
  }

  Future<void> _send() async {
    _cancelTimer();
    if (!active || _exhausted || !store.readable) return;
    final state = store.readState('retry');
    final next = state?['next_at'];
    if (state?['identity'] == identity &&
        next is num &&
        next.isFinite &&
        next > now().millisecondsSinceEpoch) {
      schedule(Duration(
          milliseconds: (next - now().millisecondsSinceEpoch)
              .clamp(1, 86400000)
              .toInt()));
      return;
    }
    var batches = 0;
    final envelopeBytes = _encode(const []).length;
    while (active && store.hasPending) {
      final batch = <QueueEntry>[];
      var size = envelopeBytes;
      for (final entry in store.pending.take(50)) {
        final nextSize = size + entry.bytes - 1 + (batch.isEmpty ? 0 : 1);
        if (nextSize > 512 * 1024) break;
        batch.add(entry);
        size = nextSize;
      }
      if (batch.isEmpty) return;
      final response = await transport.send(_encode(batch));
      lastStatus = response.status;
      final ok = response.status >= 200 && response.status < 300;
      lastError = ok
          ? null
          : (response.status == 401 || response.status == 403)
              ? 'unauthorized'
              : 'http_${response.status}';
      if (ok) lastSentAt = now();
      if (!active) return;
      if (response.status == 401 || response.status == 403) {
        disabled = true;
        store.writeState('disabled', {'identity': identity});
        _cancelTimer();
        return;
      }
      if (response.status >= 200 && response.status < 300) {
        final indexes = confirmed(response.body, batch.length);
        if (indexes == null || indexes.isEmpty) {
          _retry();
          return;
        }
        if (!store.acknowledge(batch, indexes)) {
          _retry();
          return;
        }
        if (indexes.length != batch.length) {
          _retry();
          return;
        }
      } else if ([400, 413, 415, 422].contains(response.status)) {
        if (!store.acknowledge(batch, List.generate(batch.length, (i) => i))) {
          _retry();
          return;
        }
      } else {
        _retry(
            after: response.status == 429
                ? retryAfter(response.retryAfter, now())
                : null);
        return;
      }
      _attempts = 0;
      store.writeState('retry', {'identity': identity, 'next_at': 0});
      // Yield between groups without ending a drain prematurely at three batches.
      if (++batches % 3 == 0) await Future<void>.delayed(Duration.zero);
    }
  }

  List<int> _encode(List<QueueEntry> batch) => utf8.encode(jsonEncode({
        'app': config.app,
        'sdk': {
          'name': 'moo-monitor-flutter',
          'version': sdkVersion,
          'schema': 1
        },
        'records': batch.map((entry) => entry.record).toList(),
      }));

  static List<int>? confirmed(List<int> bytes, int count) {
    try {
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map || data['ok'] != true || data['results'] is! List) {
        return null;
      }
      final results = data['results'] as List;
      if (results.length != count) return null;
      final seen = <int>{}, confirmed = <int>[];
      for (final row in results) {
        if (row is! Map || row['index'] is! int) return null;
        final index = row['index'] as int;
        if (index < 0 || index >= count || !seen.add(index)) return null;
        switch (row['status']) {
          case 'saved':
          case 'created':
          case 'updated':
          case 'duplicate':
          case 'filtered':
            confirmed.add(index);
          case 'skipped':
            if (row['retryable'] == false) confirmed.add(index);
          default:
            return null;
        }
      }
      return confirmed;
    } catch (_) {
      return null;
    }
  }

  static Duration? retryAfter(String? value, DateTime now) {
    if (value == null) return null;
    final number = double.tryParse(value.trim());
    if (number != null && number.isFinite && number >= 0) {
      return Duration(
          milliseconds: (number.clamp(0, 315576000) * 1000).toInt());
    }
    try {
      return Duration(
          milliseconds: (HttpDate.parse(value).millisecondsSinceEpoch -
                  now.millisecondsSinceEpoch)
              .clamp(0, 315576000000));
    } catch (_) {
      return null;
    }
  }

  void _retry({Duration? after}) {
    if (!active) return;
    const backoff = [30, 120, 480, 1800, 1800, 1800];
    _attempts++;
    final delay =
        after ?? Duration(seconds: backoff[(_attempts - 1).clamp(0, 5)]);
    store.writeState('retry', {
      'identity': identity,
      'next_at': now()
          .add(delay < const Duration(seconds: 1)
              ? const Duration(seconds: 1)
              : delay)
          .millisecondsSinceEpoch
    });
    _exhausted = _attempts >= 6;
    schedule(delay < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : delay);
  }

  void close() {
    if (_closed) return;
    _persistSession(clean: true);
    _closed = true;
    _cancelTimer();
    transport.close();
  }
}

class _MemoryWarning implements Exception {
  const _MemoryWarning();
}

class _UncleanExit implements Exception {
  const _UncleanExit();
}

class _NativeEvent implements Exception {
  const _NativeEvent();
}
