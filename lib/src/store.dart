import 'dart:convert';
import 'dart:io';
import 'dart:math';

class QueueEntry {
  QueueEntry(this.line, this.record) : bytes = utf8.encode(line).length + 1;
  final String line;
  final Map<String, dynamic> record;
  final int bytes;
}

/// One root isolate owns this directory. All mutations complete synchronously.
class EventStore {
  EventStore(this.directory,
      {int maxRecords = 200, int maxBytes = 2 * 1024 * 1024})
      : maxRecords = maxRecords.clamp(1, 200),
        maxBytes = maxBytes.clamp(1, 2 * 1024 * 1024) {
    try {
      directory.createSync(recursive: true);
      _load();
    } catch (_) {
      readable = false;
    }
  }
  final Directory directory;
  final int maxRecords, maxBytes;
  final _entries = <QueueEntry>[];
  int _bytes = 0, dropped = 0;
  bool readable = true;
  File get _queue => File('${directory.path}/queue.jsonl');
  List<QueueEntry> get pending => List.unmodifiable(_entries);

  void _load() {
    final type = FileSystemEntity.typeSync(_queue.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('invalid queue source');
    }
    final file = _queue.openSync();
    late List<int> data;
    var repaired = false;
    try {
      final length = file.lengthSync();
      final start = max(0, length - (2 * 1024 * 1024 + 256 * 1024));
      file.setPositionSync(start);
      data = file.readSync(length - start);
      if (start > 0) {
        final boundary = data.indexOf(10);
        data = boundary < 0 ? [] : data.sublist(boundary + 1);
        repaired = true;
        dropped++;
      }
    } finally {
      file.closeSync();
    }
    for (final line in utf8.decode(data, allowMalformed: true).split('\n')) {
      if (line.isEmpty) continue;
      try {
        final record = jsonDecode(line);
        if (record is! Map<String, dynamic> ||
            utf8.encode(line).length > 256 * 1024) {
          throw const FormatException();
        }
        _entries.add(QueueEntry(line, record));
      } catch (_) {
        repaired = true;
        dropped++;
      }
    }
    _bytes = _entries.fold(0, (n, entry) => n + entry.bytes);
    if (data.isNotEmpty && data.last != 10) repaired = true;
    if (_trim()) repaired = true;
    if (repaired) _replace(_entries);
  }

  bool append(Map<String, dynamic> record) {
    if (!readable) {
      dropped++;
      return false;
    }
    try {
      final id = record['event_id'];
      if (id != null &&
          _entries.any((entry) => entry.record['event_id'] == id)) {
        return true;
      }
      final line = jsonEncode(record);
      final entry = QueueEntry(line, jsonDecode(line) as Map<String, dynamic>);
      if (entry.bytes > min(maxBytes, 256 * 1024 + 1)) {
        dropped++;
        return false;
      }
      _queue.writeAsStringSync('${entry.line}\n',
          mode: FileMode.append, flush: true);
      _entries.add(entry);
      _bytes += entry.bytes;
      if (_trim()) _replace(_entries);
      return true;
    } catch (_) {
      readable = false;
      dropped++;
      return false;
    }
  }

  bool _trim() {
    if (_entries.length <= maxRecords && _bytes <= maxBytes) return false;
    while (_entries.isNotEmpty &&
        (_entries.length > max(1, maxRecords * 3 ~/ 4) || _bytes > maxBytes)) {
      _bytes -= _entries.removeAt(0).bytes;
      dropped++;
    }
    return true;
  }

  bool acknowledge(List<QueueEntry> batch, List<int> indexes) {
    if (!readable || indexes.any((i) => i < 0 || i >= batch.length)) {
      return false;
    }
    final receipts = <String, int>{};
    for (final index in indexes) {
      receipts.update(batch[index].line, (n) => n + 1, ifAbsent: () => 1);
    }
    final rest = _entries.where((entry) {
      final count = receipts[entry.line] ?? 0;
      if (count > 0) receipts[entry.line] = count - 1;
      return count == 0;
    }).toList();
    try {
      _replace(rest);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _replace(List<QueueEntry> entries) {
    final snapshot = entries.toList();
    final temp = File('${_queue.path}.tmp');
    temp.writeAsStringSync(snapshot.map((e) => '${e.line}\n').join(),
        flush: true);
    temp.renameSync(_queue.path);
    _entries
      ..clear()
      ..addAll(snapshot);
    _bytes = snapshot.fold(0, (n, entry) => n + entry.bytes);
  }

  Map<String, dynamic>? readState(String name) {
    try {
      return jsonDecode(File('${directory.path}/$name.json').readAsStringSync())
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  bool writeState(String name, Map<String, dynamic> data) {
    try {
      final target = '${directory.path}/$name.json';
      File('$target.tmp').writeAsStringSync(jsonEncode(data), flush: true);
      File('$target.tmp').renameSync(target);
      return true;
    } catch (_) {
      return false;
    }
  }
}
