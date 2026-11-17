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
  HttpClient? _client;
  bool _closed = false;

  HttpClient _ensure() {
    if (_closed) throw StateError('closed');
    return _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
  }

  @override
  Future<HttpResult> send(List<int> body) async {
    final client = _ensure();
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
        final retryAfter = response.headers.value(HttpHeaders.retryAfterHeader);
        final bytes = BytesBuilder(copy: false);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 128 * 1024) {
              throw const FormatException('response too large');
            }
            bytes.add(chunk);
          }
        } else {
          // Drain error bodies so the kept-alive connection stays reusable.
          await response.drain<void>();
        }
        return HttpResult(response.statusCode, bytes.takeBytes(),
            retryAfter: retryAfter);
      })()
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // Any thrown error (timeout, reset, oversized) taints the pooled socket.
      _client?.close(force: true);
      _client = null;
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client?.close(force: true);
    _client = null;
  }
}
