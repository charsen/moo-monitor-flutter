import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:moo_monitor_flutter/src/redactor.dart';

class PrivateObject {
  @override
  String toString() => throw StateError('must not call');
}

void main() {
  test('short quoted prefixed credentials private filenames URLs are removed',
      () {
    final text = Redactor.scrub(
        '''db_password="two secret words" token=tiny Bearer abc.def.ghi file:///private/var/test book.epub''');
    for (final secret in [
      'two secret words',
      'tiny',
      'abc.def.ghi',
      'test book.epub'
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });
  test('shared graph has a total budget and never calls unknown descriptions',
      () {
    Object graph = {'token': 'tiny', 'long': '汉' * 20000};
    for (var i = 0; i < 9; i++) {
      graph = List.filled(16, graph);
    }
    final value = Redactor.payload(
        {'graph': graph, 'object': PrivateObject(), 'nan': double.nan},
        dropped: 7);
    expect(utf8.encode(jsonEncode(value)).length, lessThanOrEqualTo(8192));
    expect(value['dropped'], 7);
    expect(jsonEncode(value), isNot(contains('tiny')));
  });
  test('UTF8 limits remain valid for multibyte and control data', () {
    expect(utf8.encode(Redactor.scrub('汉' * 10000)).length,
        lessThanOrEqualTo(8192));
    expect(Redactor.payload({'text': '\x00' * 8192}, dropped: 9)['dropped'], 9);
  });
  test('Dart source identity remains readable and absolute paths do not escape',
      () {
    const symbol =
        'ReaderSelectionCoordinatorWithLongClassName.persistCurrentSelectionForDocumentBoundary';
    expect(Redactor.scrub(symbol), symbol);
    final frames = Redactor.frames(
        '#0 Reader.load (package:example/reader.dart:42:9)\n#1 main (/Users/private/project/main.dart:3:2)\n#2 x (dart:async/future.dart:1:2)');
    expect(frames[0]['file'], 'package:example/reader.dart');
    expect(frames[0]['line'], 42);
    expect(frames[1]['file'], 'main.dart');
    expect(frames[2]['app'], false);
    expect(Redactor.frames('*** AOT obfuscated address'), isEmpty);
  });
  test('third-party package ownership is never guessed as app code', () {
    const stack =
        '#0 Dependency.call (package:dio/client.dart:2:3)\n#1 Reader.load (package:core/reader.dart:4:5)';
    final frames = Redactor.frames(stack, inAppPackages: {'core'});
    expect(frames[0]['app'], false);
    expect(frames[1]['app'], true);
    expect(Redactor.frames(stack).every((f) => f['app'] == false), isTrue);
  });
  test('business screens and route parameters are rejected', () {
    expect(Redactor.screen('ReaderView'), 'ReaderView');
    for (final value in ['书名', '/book/123', 'book title', 'x' * 65]) {
      expect(Redactor.screen(value), isNull);
    }
  });
}
