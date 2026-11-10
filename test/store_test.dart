import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:moo_monitor_flutter/src/store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('monitor-store-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('repairs corrupt and complete-but-unterminated lines once', () {
    File('${dir.path}/queue.jsonl')
        .writeAsStringSync('bad\n{"event_id":"a"}\n{"event_id":"b"}');
    final store = EventStore(dir);
    expect(store.pending.map((e) => e.record['event_id']), ['a', 'b']);
    expect(store.dropped, 1);
    store.append({'event_id': 'c'});
    expect(EventStore(dir).pending.length, 3);
    expect(EventStore(dir).dropped, 0);
  });
  test('count and byte caps both hold with distinct events', () {
    final store = EventStore(dir, maxBytes: 1500);
    for (var i = 0; i < 200; i++) {
      store.append({'event_id': '$i', 'message': 'x' * 300});
    }
    expect(store.pending.length, lessThanOrEqualTo(200));
    expect(
        File('${dir.path}/queue.jsonl').lengthSync(), lessThanOrEqualTo(1500));
    expect(store.pending.last.record['event_id'], '199');
    expect(store.dropped, greaterThan(0));
  });
  test('immutable receipts survive appends and rotation', () {
    final store = EventStore(dir, maxRecords: 3);
    store.append({'event_id': 'a'});
    store.append({'event_id': 'b'});
    final batch = store.pending;
    store.append({'event_id': 'c'});
    store.append({'event_id': 'd'});
    expect(store.acknowledge(batch, [0, 1]), isTrue);
    expect(store.pending.map((e) => e.record['event_id']), ['c', 'd']);
  });
  test('stored snapshot cannot be changed by caller after serialization', () {
    final record = <String, dynamic>{
      'event_id': 'a',
      'payload': {'value': 1}
    };
    final store = EventStore(dir)..append(record);
    (record['payload'] as Map)['value'] = 2;
    expect((store.pending.single.record['payload'] as Map)['value'], 1);
  });
  test('stable event ID replay is not a second occurrence', () {
    final store = EventStore(dir);
    store.append({'event_id': 'a', 'count': 1});
    store.append({'event_id': 'a', 'count': 1});
    expect(EventStore(dir).pending.length, 1);
    expect(utf8.decode(File('${dir.path}/queue.jsonl').readAsBytesSync()),
        contains('"count":1'));
  });
  test('read failure never overwrites unknown queue source', () {
    Directory('${dir.path}/queue.jsonl').createSync();
    final store = EventStore(dir);
    expect(store.readable, isFalse);
    expect(store.append({'event_id': 'a'}), isFalse);
    expect(Directory('${dir.path}/queue.jsonl').existsSync(), isTrue);
  });
}
