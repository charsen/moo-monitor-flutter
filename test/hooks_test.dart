import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moo_monitor_flutter/moo_monitor_flutter.dart';
import 'package:moo_monitor_flutter/src/store.dart';

void failIsolate(dynamic value) {
  throw StateError('child fixture');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FlutterExceptionHandler? oldFlutter;
  late ErrorCallback? oldPlatform;
  const config = MonitorConfig(
      token: 'fixture',
      app: 'fixture',
      platform: 'android',
      endpoint: 'http://127.0.0.1:1');
  setUp(() {
    dir = Directory.systemTemp.createTempSync('monitor-hooks-');
    oldFlutter = FlutterError.onError;
    oldPlatform = PlatformDispatcher.instance.onError;
  });
  tearDown(() async {
    await MooMonitor.close();
    FlutterError.onError = oldFlutter;
    PlatformDispatcher.instance.onError = oldPlatform;
    dir.deleteSync(recursive: true);
  });
  test('framework and root hooks preserve original handler and boolean result',
      () async {
    var framework = 0, platform = 0;
    FlutterError.onError = (_) {
      framework++;
    };
    PlatformDispatcher.instance.onError = (_, __) {
      platform++;
      return false;
    };
    final original = FlutterError.onError;
    expect(await MooMonitor.install(config, directory: dir), isTrue);
    FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('private book contents'),
        stack: StackTrace.current));
    expect(
        PlatformDispatcher.instance.onError!(
            StateError('fixture'), StackTrace.current),
        isFalse);
    expect(framework, 1);
    expect(platform, 1);
    final records = EventStore(dir).pending;
    expect(records.length, 2);
    expect(File('${dir.path}/queue.jsonl').readAsStringSync(),
        isNot(contains('private book contents')));
    expect(records.every((e) => e.record['kind'] == 'handled'), isTrue);
    await MooMonitor.close();
    expect(identical(FlutterError.onError, original), isTrue);
  });
  test('disposing does not replace a handler installed later by the host',
      () async {
    await MooMonitor.install(config, directory: dir);
    void newer(FlutterErrorDetails _) {}
    FlutterError.onError = newer;
    await MooMonitor.close();
    expect(identical(FlutterError.onError, newer), isTrue);
  });
  test('real memory-pressure observer includes only numeric runtime snapshots',
      () async {
    await MooMonitor.install(config, directory: dir, installHandlers: false);
    WidgetsBinding.instance.handleMemoryPressure();
    final records = EventStore(dir).pending;
    expect(records.length, 1);
    final record = records.single.record, payload = record['payload'] as Map;
    expect(record['kind'], 'low_memory');
    for (final key in [
      'image_cache_bytes',
      'image_cache_count',
      'image_cache_live_count',
      'image_cache_pending_count'
    ]) {
      expect(payload[key], isA<int>());
      expect(payload[key] as int, greaterThanOrEqualTo(0));
    }
    expect(payload['process_rss_bytes'], isA<int>());
    expect(payload['process_peak_rss_bytes'], isA<int>());
  });
  test('empty token does not create directory or install handlers', () async {
    final absent = Directory('${dir.path}/absent');
    final original = FlutterError.onError;
    expect(
        await MooMonitor.install(
            const MonitorConfig(token: '', app: 'fixture', platform: 'android'),
            directory: absent),
        isFalse);
    expect(absent.existsSync(), isFalse);
    expect(identical(FlutterError.onError, original), isTrue);
  });
  test('unwritable directory fails installation without changing handlers',
      () async {
    final file = File('${dir.path}/file')..writeAsStringSync('fixture');
    final original = FlutterError.onError;
    expect(await MooMonitor.install(config, directory: Directory(file.path)),
        isFalse);
    expect(identical(FlutterError.onError, original), isTrue);
  });
  test('paused child isolate error is explicitly forwarded once', () async {
    await MooMonitor.install(config, directory: dir, installHandlers: false);
    final isolate = await Isolate.spawn(failIsolate, null, paused: true);
    MooMonitor.observeIsolate(isolate);
    isolate.resume(isolate.pauseCapability!);
    for (var i = 0; i < 100 && EventStore(dir).pending.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    MooMonitor.stopObservingIsolate(isolate);
    final records = EventStore(dir).pending;
    expect(records.length, 1);
    expect(
        (records.single.record['payload'] as Map)['source'], 'child_isolate');
  });
  test(
      'removing or replacing background routes never changes the visible screen',
      () async {
    await MooMonitor.install(config, directory: dir, installHandlers: false);
    final observer =
        MonitorNavigatorObserver(screenName: (r) => r.settings.name);
    Route<void> route(String name) => PageRouteBuilder<void>(
        settings: RouteSettings(name: name),
        pageBuilder: (_, __, ___) => const SizedBox());
    final first = route('LibraryView'),
        second = route('ReaderView'),
        top = route('SettingsView');
    observer.didPush(first, null);
    observer.didPush(second, first);
    observer.didPush(top, second);
    observer.didRemove(second, first);
    observer.didReplace(
        oldRoute: first, newRoute: route('OtherBackgroundView'));
    MooMonitor.capture(StateError('fixture'), StackTrace.empty);
    expect((EventStore(dir).pending.single.record['context'] as Map)['screen'],
        'SettingsView');
  });
  test('navigation pop restores safe previous screen without arguments',
      () async {
    await MooMonitor.install(config, directory: dir, installHandlers: false);
    final observer =
        MonitorNavigatorObserver(screenName: (r) => r.settings.name);
    final first = PageRouteBuilder<void>(
        settings: const RouteSettings(
            name: 'LibraryView', arguments: {'book': 'private'}),
        pageBuilder: (_, __, ___) => const SizedBox());
    final second = PageRouteBuilder<void>(
        settings: const RouteSettings(name: 'ReaderView'),
        pageBuilder: (_, __, ___) => const SizedBox());
    observer.didPush(first, null);
    observer.didPush(second, first);
    observer.didPop(second, first);
    MooMonitor.capture(StateError('fixture'), StackTrace.empty);
    final record = EventStore(dir).pending.single.record;
    expect((record['context'] as Map)['screen'], 'LibraryView');
    expect(record.toString(), isNot(contains('private')));
  });
}
