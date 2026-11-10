import 'dart:convert';

class Redactor {
  static final _secrets = RegExp(
    r'''["']?[\w-]*(?:token|secret|password|passwd|pwd|authorization|cookie|api[_-]?key)[\w-]*["']?\s*[:=]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&}\]]+)''',
    caseSensitive: false,
  );
  static final _secretKey = RegExp(
    r'token|secret|password|passwd|pwd|authorization|cookie|api.?key|account|email|phone|book|content',
    caseSensitive: false,
  );
  static final _urls =
      RegExp(r'''(?:https?|file)://[^\r\n)\]"']+''', caseSensitive: false);
  static final _paths = RegExp(
      r'''(?:/(?:private|Users|Volumes|data|storage|var|home)/)[^\r\n)\]"']+''');
  static final _bearer = RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false);
  static final _jwt =
      RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+');

  static String truncate(String text, int bytes) {
    // Bound allocation before UTF-8 encoding; a UTF-16 unit uses at least one byte.
    final data = utf8.encode(text.substring(0, text.length.clamp(0, bytes)));
    if (data.length <= bytes) return utf8.decode(data, allowMalformed: true);
    var end = bytes;
    while (end > 0 && (data[end] & 0xc0) == 0x80) {
      end--;
    }
    return utf8.decode(data.sublist(0, end), allowMalformed: true);
  }

  static String scrub(String text, {int bytes = 8192}) {
    var value = truncate(text, bytes);
    value = value
        .replaceAll(_secrets, '[credential]')
        .replaceAll(_bearer, 'Bearer ***')
        .replaceAll(_jwt, '[credential]')
        .replaceAll(_urls, '[url]')
        .replaceAll(_paths, '[path]');
    return truncate(value, bytes);
  }

  static String? screen(String name) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_.]{0,63}$').hasMatch(name) ? name : null;

  static Map<String, dynamic> payload(Map<String, Object?> input,
      {int dropped = 0}) {
    var nodes = 128, bytes = 8192;
    Object? visit(Object? value, int depth) {
      if (--nodes < 0 || depth > 4 || bytes <= 0) return '[truncated]';
      if (value == null || value is bool) return value;
      if (value is num) return value.isFinite ? value : null;
      if (value is String) {
        final clean = scrub(value, bytes: bytes);
        bytes -= utf8.encode(clean).length;
        return clean;
      }
      if (value is Map) {
        final out = <String, Object?>{};
        for (final entry in value.entries.take(16)) {
          if (nodes <= 0 || bytes <= 0) break;
          if (entry.key is! String) continue;
          final key = entry.key as String;
          final cleanKey = scrub(key, bytes: bytes.clamp(0, 64));
          bytes -= utf8.encode(cleanKey).length;
          out[cleanKey] =
              _secretKey.hasMatch(key) ? '***' : visit(entry.value, depth + 1);
        }
        return out;
      }
      if (value is List) {
        final out = <Object?>[];
        for (final item in value.take(16)) {
          if (nodes <= 0 || bytes <= 0) break;
          out.add(visit(item, depth + 1));
        }
        return out;
      }
      return '[unsupported]';
    }

    final out = Map<String, dynamic>.from(visit(input, 0) as Map? ?? {});
    if (dropped > 0) out['dropped'] = dropped;
    if (utf8.encode(jsonEncode(out)).length <= 8192) return out;
    return {
      '__truncated': true,
      if (out['runtime'] == 'flutter') 'runtime': 'flutter',
      if (out['source'] is String)
        'source': truncate(out['source'] as String, 64),
      if (out['uptime_ms'] is int) 'uptime_ms': out['uptime_ms'],
      if (dropped > 0) 'dropped': dropped,
    };
  }

  static List<Map<String, Object>> frames(String stack,
      {Set<String> inAppPackages = const {}}) {
    final out = <Map<String, Object>>[];
    final pattern = RegExp(r'^#\d+\s+(.+?) \((.+):(\d+):(\d+)\)$');
    for (final line in stack.split('\n').take(100)) {
      final match = pattern.firstMatch(line.trim());
      if (match == null) continue;
      final uri = match[2]!;
      final file = uri.startsWith('package:') || uri.startsWith('dart:')
          ? uri
          : uri.split(RegExp(r'[/\\]')).last;
      out.add({
        'function': scrub(match[1]!, bytes: 256),
        'file': scrub(file, bytes: 256),
        'line': int.parse(match[3]!),
        'column': int.parse(match[4]!),
        'app': uri.startsWith('package:') &&
            inAppPackages.contains(uri.substring(8).split('/').first),
      });
      if (out.length == 60) break;
    }
    return out;
  }
}
