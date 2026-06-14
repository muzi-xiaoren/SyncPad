import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';

/// 负责把 [LogRecord] 行追加 / 读取到磁盘日志文件。
/// 物理路径：`<app_support_dir>/SyncPad/notes.log`
class LogStore {
  LogStore._(this._file);

  final File _file;

  static Future<LogStore> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'SyncPad'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dir.path, 'notes.log'));
    if (!await file.exists()) {
      await file.writeAsString('');
    }
    return LogStore._(file);
  }

  File get file => _file;
  String get path => _file.path;

  Future<int> sizeBytes() async => _file.length();

  /// 一次性读取所有行（小文件 OK）。
  Future<List<LogRecord>> readAll() async {
    final out = <LogRecord>[];
    if (!await _file.exists()) return out;
    final lines = await _file.readAsLines();
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      try {
        out.add(LogRecord.fromLine(line));
      } catch (_) {
        // 一行坏不能搞挂整个 store，跳过并继续
        continue;
      }
    }
    return out;
  }

  Future<void> append(LogRecord record) async {
    final sink = _file.openWrite(mode: FileMode.append);
    try {
      sink.writeln(record.toLine());
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// 用一组新记录原子替换整个日志（compaction / 从远端覆盖时使用）。
  Future<void> replaceAll(Iterable<LogRecord> records) async {
    final tmp = File('${_file.path}.tmp');
    final sink = tmp.openWrite();
    try {
      for (final r in records) {
        sink.writeln(r.toLine());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    await tmp.rename(_file.path);
  }
}
