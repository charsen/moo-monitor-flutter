import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:moo_monitor_flutter/src/client.dart';
import 'package:moo_monitor_flutter/src/config.dart';
import 'package:moo_monitor_flutter/src/store.dart';
import 'package:moo_monitor_flutter/src/transport.dart';

class _ReentrantError implements Exception {
  _ReentrantError(this.read, {this.text = 'outer'});
  final void Function() read;
  final String text;
  @override
  int get hashCode => 7;
  @override
  bool operator ==(Object other) => identical(this, other);
  @override
  String toString() {
    read();
    return text;
  }
}

class _ReentrantMap extends MapBase<String, Object?> {
  _ReentrantMap(this.read);
  final void Function() read;
  @override
  Iterable<String> get keys {
    read();
    return const ['counter'];
  }

  @override
  Object? operator [](Object? key) => key == 'counter' ? 1 : null;
  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

class _ThrowingStack implements StackTrace {
  @override
  String toString() => throw StateError('synthetic serialization failure');
}

class FakeTransport implements MonitorTransport {
  FakeTransport(this.handler);
  final Future<HttpResult> Function(List<dynamic> records) handler;
  final requests = <List<dynamic>>[];
  final sizes = <int>[];
  @override
  Future<HttpResult> send(List<int> body) async {
    final records = (jsonDecode(utf8.decode(body)) as Map)['records'] as List;
    requests.add(records);
    sizes.add(body.length);
    return handler(records);
  }

  @override
  void close() {}
}

HttpResult receipt(List<dynamic> records) => HttpResult(
    200,
    utf8.encode(jsonEncode({
      'ok': true,
      'results':
          List.generate(records.length, (i) => {'index': i, 'status': 'saved'})
    })));
void main() {
  late Directory dir;
  final clients = <MonitorClient>[];
  var now = DateTime.utc(2026, 11, 10);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('monitor-client-');
    now = DateTime.utc(2026, 11, 10);
  });
  tearDown(() {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    dir.deleteSync(recursive: true);
  });
  MonitorClient make(FakeTransport transport,
      {String token = 'fixture',
      int maxRecords = 200,
      Map<String, int> Function()? snapshot}) {
    final client = MonitorClient(
        MonitorConfig(token: token, app: 'fixture', platform: 'android'),
        EventStore(dir, maxRecords: maxRecords),
        transport: transport,
        now: () => now,
        automatic: false,
        memorySnapshot: snapshot);
    clients.add(client);
    return client;
  }

  void capture(MonitorClient client, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      client.capture(
          StateError('fixture token=tiny'),
          StackTrace.fromString(
              '#0 Fixture.read (package:fixture/read.dart:2:3)'));
    }
  }

  test(
      'recursive descriptions are skipped without suppressing later attempts or hash collisions',
      () {
    final client = make(FakeTransport((r) async => receipt(r)));
    final error = _ReentrantError(
        () => client.capture(StateError('nested'), StackTrace.empty));
    client.capture(error, StackTrace.empty);
    client.capture(error, StackTrace.empty);
    client.capture(_ReentrantError(() {}, text: 'other'), StackTrace.empty);
    final rows = client.store.pending.map((r) => r.record).toList();
    expect(rows.length, 3);
    expect(rows.map((r) => (r['exception'] as Map)['message']),
        ['outer', 'outer', 'other']);
    expect(rows.map((r) => r['event_id']).toSet().length, 3);
  });
  test('extras enumeration cannot recursively capture another event', () {
    final client = make(FakeTransport((r) async => receipt(r)));
    client.capture(StateError('outer'), StackTrace.empty,
        kind: 'low_memory',
        extras: _ReentrantMap(
            () => client.capture(StateError('nested'), StackTrace.empty)));
    expect(client.store.pending.length, 1);
    expect(client.store.pending.single.record['kind'], 'low_memory');
  });
  test('capture guard releases after serialization fails', () {
    final client = make(FakeTransport((r) async => receipt(r)));
    client.capture(StateError('bad'), _ThrowingStack());
    expect(client.store.dropped, 1);
    client.capture(StateError('after'), StackTrace.empty, message: 'after');
    expect((client.store.pending.single.record['exception'] as Map)['message'],
        'after');
  });
  test('close during error construction cannot append after collection stops',
      () {
    final client = make(FakeTransport((r) async => receipt(r)));
    client.capture(StateError('kept'), StackTrace.empty, message: 'kept');
    final before = File('${dir.path}/queue.jsonl').readAsBytesSync();
    client.capture(_ReentrantError(client.close), StackTrace.empty);
    expect(client.active, isFalse);
    expect(File('${dir.path}/queue.jsonl').readAsBytesSync(), before);
    expect(client.store.pending.length, 1);
  });
  test('close during extras enumeration keeps prior evidence unchanged', () {
    final client = make(FakeTransport((r) async => receipt(r)));
    client.capture(StateError('kept'), StackTrace.empty, message: 'kept');
    final before = File('${dir.path}/queue.jsonl').readAsBytesSync();
    client.capture(StateError('discard'), StackTrace.empty,
        extras: _ReentrantMap(client.close));
    expect(File('${dir.path}/queue.jsonl').readAsBytesSync(), before);
    expect(client.store.pending.length, 1);
  });
  test('late successful receipt after close cannot acknowledge evidence',
      () async {
    final response = Completer<HttpResult>();
    final client = make(FakeTransport((r) => response.future));
    capture(client);
    final before = File('${dir.path}/queue.jsonl').readAsBytesSync();
    final sending = client.flush();
    client.close();
    response.complete(HttpResult(200,
        utf8.encode('{"ok":true,"results":[{"index":0,"status":"saved"}]}')));
    await sending;
    expect(File('${dir.path}/queue.jsonl').readAsBytesSync(), before);
  });
  test('cross-platform breadcrumbs reject request data and credentials', () {
    final rows = jsonDecode(
            File('test/fixtures/cross-sdk-breadcrumbs.json').readAsStringSync())
        as List;
    for (final row in rows.cast<Map>()) {
      final client = make(FakeTransport((r) async => receipt(r)));
      client.breadcrumb(row['type'] as String, row['name'] as String);
      client.capture(StateError('fixture'), StackTrace.empty);
      final crumbs = client.store.pending.last.record['breadcrumbs'] as List;
      expect(crumbs.length, row['accepted'] == true ? 1 : 0);
    }
  });
  test('repeated sync requests keep earlier transitions and bounded snapshots',
      () {
    final client = make(FakeTransport((r) async => receipt(r)));
    client.breadcrumb('sync', 'reader.identity.ok');
    for (var i = 0; i < 1000; i++) {
      client.breadcrumb('sync', 'reader.changes.timeout');
    }
    expect(client.store.pending, isEmpty);
    client.capture(StateError('first'), StackTrace.empty);
    final frozen = client.store.pending.single.record['breadcrumbs'] as List;
    expect(frozen.map((c) => (c as Map)['name']),
        ['reader.identity.ok', 'reader.changes.timeout']);
    for (var i = 0; i < 35; i++) {
      client.breadcrumb('sync', 'reader.phase_$i.ok');
    }
    client.capture(StateError('second'), StackTrace.empty);
    final tail = client.store.pending.last.record['breadcrumbs'] as List;
    expect(tail.length, 30);
    expect((tail.first as Map)['name'], 'reader.phase_5.ok');
    expect((tail.last as Map)['name'], 'reader.phase_34.ok');
    expect(client.store.pending.first.record['breadcrumbs'], frozen);
  });

  test('180 distinct events drain beyond three bounded batches', () async {
    final transport = FakeTransport((r) async => receipt(r));
    final client = make(transport);
    capture(client, 180);
    await client.flush();
    expect(transport.requests.map((e) => e.length), [50, 50, 50, 30]);
    expect(transport.sizes.every((n) => n <= 512 * 1024), isTrue);
    expect(client.store.pending, isEmpty);
    final events = transport.requests.expand((x) => x).toList();
    expect(events.map((x) => x['event_id']).toSet().length, 180);
    expect(jsonEncode(events), isNot(contains('tiny')));
  });
  test(
      'capture cleans the original stack before truncating and deriving frames',
      () {
    final client = make(FakeTransport((r) async => receipt(r)));
    final jwt = 'eyJ${'A' * 40000}.payload.signature';
    client.capture(
        StateError('fixture'), StackTrace.fromString('failure $jwt'));
    final record = client.store.pending.single.record;
    expect(jsonEncode(record), isNot(contains('eyJAAA')));
    expect(utf8.encode((record['exception'] as Map)['stack'] as String).length,
        lessThanOrEqualTo(32768));
  });
  test('concurrent flush shares a request and new append survives receipt',
      () async {
    final gate = Completer<HttpResult>();
    final transport = FakeTransport((r) => gate.future);
    final client = make(transport, maxRecords: 2);
    capture(client);
    final first = client.flush();
    final second = client.flush();
    expect(identical(first, second), isTrue);
    capture(client, 3);
    gate.complete(HttpResult(
        200,
        utf8.encode(
            '{"ok":true,"results":[{"index":0,"status":"skipped","retryable":true}]}')));
    await first;
    expect(transport.requests.length, 1);
    expect(client.store.pending.length, greaterThan(0));
    expect(client.store.pending.last.record['event_id'],
        isNot(transport.requests.single.single['event_id']));
  });
  test(
      'partial receipts acknowledge only terminal rows then retry original event',
      () async {
    var attempt = 0;
    final transport = FakeTransport((r) async => ++attempt == 1
        ? HttpResult(
            200,
            utf8.encode(
                '{"ok":true,"results":[{"index":0,"status":"saved"},{"index":1,"status":"skipped","retryable":true}]}'))
        : receipt(r));
    final client = make(transport);
    capture(client, 2);
    final id = client.store.pending.last.record['event_id'];
    await client.flush();
    expect(client.store.pending.length, 1);
    now = now.add(const Duration(minutes: 1));
    await client.flush();
    expect(transport.requests.last.single['event_id'], id);
    expect(client.store.pending, isEmpty);
  });
  test(
      'malformed incomplete duplicate and non-boolean receipts never clear queue',
      () {
    for (final body in [
      '{}',
      '{"ok":1,"results":[]}',
      '{"ok":true,"results":[{"index":0,"status":"saved"},{"index":0,"status":"saved"}]}',
      '{"ok":true,"results":[{"index":0.0,"status":"saved"}]}',
      '{"ok":true,"results":[{"index":true,"status":"saved"}]}'
    ]) {
      expect(MonitorClient.confirmed(utf8.encode(body), 2), isNull);
    }
    expect(
        MonitorClient.confirmed(
            utf8.encode(
                '{"ok":true,"results":[{"index":0,"status":"filtered"},{"index":1,"status":"skipped","retryable":false}]}'),
            2),
        [0, 1]);
  });
  test(
      '401 retains evidence stops capture and new token restores after restart',
      () async {
    final client = make(FakeTransport((r) async => HttpResult(401, [])));
    capture(client);
    final id = client.store.pending.single.record['event_id'];
    await client.flush();
    capture(client);
    expect(client.disabled, isTrue);
    expect(client.store.pending.length, 1);
    client.close();
    final same = make(FakeTransport((r) async => receipt(r)));
    expect(same.disabled, isTrue);
    same.close();
    final next =
        make(FakeTransport((r) async => receipt(r)), token: 'new-fixture');
    expect(next.disabled, isFalse);
    expect(next.store.pending.single.record['event_id'], id);
    await next.flush();
    expect(next.store.pending, isEmpty);
  });
  test(
      '429 wait persists across process restart and does not shorten long dates',
      () async {
    final client = make(
        FakeTransport((r) async => HttpResult(429, [], retryAfter: '7200')));
    capture(client);
    await client.flush();
    client.close();
    final transport = FakeTransport((r) async => receipt(r));
    final next = make(transport);
    now = now.add(const Duration(hours: 1));
    await next.flush();
    expect(transport.requests, isEmpty);
    now = now.add(const Duration(hours: 1));
    await next.flush();
    expect(next.store.pending, isEmpty);
    expect(
        MonitorClient.retryAfter(
            'Wed, 11 Nov 2026 00:00:00 GMT', DateTime.utc(2026, 11, 10)),
        const Duration(days: 1));
  });
  test(
      'failed service survives three restarts with same event and original build',
      () async {
    var client = make(FakeTransport((r) async => HttpResult(503, [])));
    capture(client);
    final id = client.store.pending.single.record['event_id'];
    await client.flush();
    client.close();
    for (var i = 0; i < 3; i++) {
      client = make(FakeTransport((r) async => HttpResult(503, [])));
      expect(client.store.pending.single.record['event_id'], id);
      client.close();
    }
  });
  test(
      'memory warning throttles and is not a crash; session/install IDs differ',
      () {
    final client = make(FakeTransport((r) async => receipt(r)));
    client.memoryWarning();
    client.memoryWarning();
    expect(client.store.pending.single.record['kind'], 'low_memory');
    expect(client.installId.length, 64);
    expect(client.sessionId.length, 36);
    final next = make(FakeTransport((r) async => receipt(r)));
    expect(next.installId, client.installId);
    expect(next.sessionId, isNot(client.sessionId));
  });
  test(
      'memory warnings sample fixed numeric metrics once and never private keys',
      () {
    var calls = 0;
    final client = make(FakeTransport((r) async => receipt(r)), snapshot: () {
      calls++;
      return {
        'image_cache_bytes': 1024,
        'image_cache_live_count': 3,
        'process_rss_bytes': 123456,
        'process_peak_rss_bytes': 234567,
        'image_cache_pending_count': -1,
        'private-book': 99
      };
    });
    client.memoryWarning();
    client.memoryWarning();
    expect(calls, 1);
    final payload = client.store.pending.single.record['payload'] as Map;
    expect(payload['image_cache_bytes'], 1024);
    expect(payload['image_cache_live_count'], 3);
    expect(payload['process_rss_bytes'], 123456);
    expect(payload['process_peak_rss_bytes'], 234567);
    expect(payload.containsKey('private-book'), isFalse);
    expect(payload.containsKey('image_cache_pending_count'), isFalse);
    expect(client.store.pending.single.record['kind'], 'low_memory');
  });
  test('a failed memory sampler still records the warning', () {
    final client = make(FakeTransport((r) async => receipt(r)),
        snapshot: () => throw StateError('private sampling failure'));
    client.memoryWarning();
    final record = client.store.pending.single.record;
    expect(record['kind'], 'low_memory');
    expect(jsonEncode(record), isNot(contains('private sampling failure')));
  });
  test(
      'reserved runtime metadata survives oversized extras and cannot be forged',
      () {
    final client = make(FakeTransport((r) async => receipt(r)));
    client.capture(StateError('fixture'), StackTrace.empty, extras: {
      'pad': '\x00' * 8192,
      'runtime': 'forged',
      'source': 'forged'
    });
    final payload = client.store.pending.single.record['payload'] as Map;
    expect(payload['runtime'], 'flutter');
    expect(payload['source'], 'capture');
    expect(utf8.encode(jsonEncode(payload)).length, lessThanOrEqualTo(8192));
  });
  test('six attempts stop this process while retaining queue', () async {
    final transport = FakeTransport((r) async => HttpResult(503, []));
    final client = make(transport);
    capture(client);
    for (var i = 0; i < 8; i++) {
      now = now.add(const Duration(days: 1));
      await client.flush();
    }
    expect(transport.requests.length, 6);
    expect(client.store.pending.length, 1);
  });
}
