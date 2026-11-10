import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class HttpResult {
  HttpResult(this.status, this.body, {this.retryAfter});
  final int status;
  final List<int> body;
  final String? retryAfter;
}

abstract class MonitorTransport {
  Future<HttpResult> send(List<int> body);
  void close();
}

class IoMonitorTransport implements MonitorTransport {
  IoMonitorTransport(this.endpoint, this.token);
  final Uri endpoint;
  final String token;
  HttpClient? _active;
  bool _closed = false;

  @override
  Future<HttpResult> send(List<int> body) async {
    if (_closed) throw StateError('closed');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _active = client;
    try {
      return await (() async {
        final request = await client.postUrl(endpoint);
        request.followRedirects = false;
        request.headers.set(
            HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set('X-Project-Token', token);
        request.add(body);
        final response = await request.close();
        final bytes = BytesBuilder(copy: false);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 128 * 1024) {
              throw const FormatException('response too large');
            }
            bytes.add(chunk);
          }
        }
        return HttpResult(response.statusCode, bytes.takeBytes(),
            retryAfter: response.headers.value(HttpHeaders.retryAfterHeader));
      })()
          .timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  @override
  void close() {
    _closed = true;
    _active?.close(force: true);
  }
}
