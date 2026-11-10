import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'config.dart';
import 'redactor.dart';
import 'store.dart';
import 'transport.dart';

String newEventId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final value = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
}

class MonitorClient {
  MonitorClient(this.config, this.store,
      {MonitorTransport? transport,
      DateTime Function()? now,
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
    if (!disabled && config.enabled) schedule(const Duration(seconds: 10));
  }
  final MonitorConfig config;
  final EventStore store;
  final MonitorTransport transport;
  final DateTime Function() now;
  final bool automatic;
  late final String identity, installId;
  final String sessionId = newEventId();
  final _uptime = Stopwatch()..start();
  final _breadcrumbs = <Map<String, Object>>[];
  bool disabled = false, _closed = false, _exhausted = false;
  bool? _foreground;
  String? _screen;
  int? _lastMemoryWarning;
  int _attempts = 0;
  Timer? _timer;
  Future<void>? _flush;
  bool get active => config.enabled && !disabled && !_closed;

  void capture(Object error, StackTrace stack,
      {String? message,
      String source = 'capture',
      String kind = 'handled',
      Map<String, Object?> extras = const {}}) {
    if (!active || !['handled', 'low_memory'].contains(kind)) return;
    try {
      final trace = Redactor.truncate(stack.toString(), 32768);
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
          'name': Redactor.scrub(error.runtimeType.toString(), bytes: 192),
          'message': Redactor.scrub(text),
          'stack': Redactor.scrub(trace, bytes: 32768)
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
          if (_foreground != null) 'foreground': _foreground
        },
        'breadcrumbs':
            _breadcrumbs.map((entry) => Map<String, Object>.of(entry)).toList(),
        'payload': Redactor.payload(payload, dropped: store.dropped),
      };
      store.append(record);
      schedule(const Duration(seconds: 5));
    } catch (_) {
      store.dropped++;
    }
  }

  void screen(String value) {
    if (!active || Redactor.screen(value) == null || value == _screen) return;
    _screen = value;
    _breadcrumb('screen', value);
  }

  void lifecycle(bool foreground) {
    if (!active || foreground == _foreground) return;
    _foreground = foreground;
    _breadcrumb('lifecycle', foreground ? 'foreground' : 'background');
    _timer?.cancel();
    _timer = null;
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
    capture(const _MemoryWarning(), StackTrace.empty,
        message: 'Memory warning',
        source: 'memory_warning',
        kind: 'low_memory');
    // The event is a memory warning, never evidence of an OOM process kill.
  }

  void _breadcrumb(String type, String name) {
    _breadcrumbs.add(
        {'t': now().toUtc().toIso8601String(), 'type': type, 'name': name});
    if (_breadcrumbs.length > 30) _breadcrumbs.removeAt(0);
  }

  void schedule(Duration delay) {
    if (!automatic || !active || _exhausted || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
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
        if (active) _retry();
      } finally {
        _flush = null;
        completer.complete();
      }
    }();
    return completer.future;
  }

  Future<void> _send() async {
    _timer?.cancel();
    _timer = null;
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
    while (active && store.pending.isNotEmpty) {
      final batch = <QueueEntry>[];
      var size = _encode([]).length;
      for (final entry in store.pending.take(50)) {
        final nextSize = size + entry.bytes - 1 + (batch.isEmpty ? 0 : 1);
        if (nextSize > 512 * 1024) break;
        batch.add(entry);
        size = nextSize;
      }
      if (batch.isEmpty) return;
      final response = await transport.send(_encode(batch));
      if (!active) return;
      if (response.status == 401 || response.status == 403) {
        disabled = true;
        store.writeState('disabled', {'identity': identity});
        _timer?.cancel();
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
        'sdk': {'name': 'moo-monitor-flutter', 'version': '0.1.0', 'schema': 1},
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
    _closed = true;
    _timer?.cancel();
    transport.close();
  }
}

class _MemoryWarning implements Exception {
  const _MemoryWarning();
}
