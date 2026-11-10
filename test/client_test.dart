import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:moo_monitor_flutter/src/client.dart';
import 'package:moo_monitor_flutter/src/config.dart';
import 'package:moo_monitor_flutter/src/store.dart';
import 'package:moo_monitor_flutter/src/transport.dart';

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
      {String token = 'fixture', int maxRecords = 200}) {
    final client = MonitorClient(
        MonitorConfig(token: token, app: 'fixture', platform: 'android'),
        EventStore(dir, maxRecords: maxRecords),
        transport: transport,
        now: () => now,
        automatic: false);
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
