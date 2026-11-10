import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:moo_monitor_flutter/moo_monitor_flutter.dart';

void main() {
  test('installation without an initialized binding fails without throwing',
      () async {
    final dir = Directory.systemTemp.createTempSync('monitor-no-binding-');
    addTearDown(() async {
      await MooMonitor.close();
      dir.deleteSync(recursive: true);
    });
    expect(
        await MooMonitor.install(
            const MonitorConfig(
                token: 'fixture', app: 'fixture', platform: 'android'),
            directory: dir),
        isFalse);
    expect(MooMonitor.installed, isFalse);
  });
}
