import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:moo_monitor_flutter/src/transport.dart';

void main() {
  test('loopback transport rejects redirects does not send cookies or auth',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    final headers = <HttpHeaders>[];
    server.listen((request) async {
      calls++;
      headers.add(request.headers);
      await request.drain<void>();
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/sink');
      request.response.headers
          .set(HttpHeaders.setCookieHeader, 'private_fixture=private');
      await request.response.close();
    });
    final transport = IoMonitorTransport(
        Uri.parse('http://127.0.0.1:${server.port}/intake'), 'fixture');
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });
    for (var i = 0; i < 2; i++) {
      expect((await transport.send(utf8.encode('{}'))).status, 302);
    }
    expect(calls, 2);
    expect(
        headers.every((h) =>
            h.value(HttpHeaders.cookieHeader) == null &&
            h.value(HttpHeaders.authorizationHeader) == null),
        isTrue);
    expect(headers.first.value('X-Project-Token'), 'fixture');
  });
  test('HTTP auth challenge returns 401 and oversized success is bounded',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((request) async {
      await request.drain<void>();
      if (++calls == 1) {
        request.response.statusCode = 401;
        request.response.headers
            .set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="fixture"');
      } else {
        request.response.write('x' * (128 * 1024 + 1));
      }
      await request.response.close();
    });
    final transport = IoMonitorTransport(
        Uri.parse('http://127.0.0.1:${server.port}/intake'), 'fixture');
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });
    expect((await transport.send([])).status, 401);
    await expectLater(transport.send([]), throwsFormatException);
    expect(calls, 2);
  });
}
