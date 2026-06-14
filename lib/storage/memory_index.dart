import 'package:flutter/foundation.dart';

import '../models/note.dart';

/// 内存里的"活记录"索引：record_id → 最新一条 LogRecord。
/// 启动时由 [replay] 一次性扫日志构建；之后所有 CRUD 都直接动它。
///
/// 同时是 [ChangeNotifier]：任何写操作（[apply]/[replay]）后都会通知监听者，
/// 让列表/编辑界面无需手动 setState 即可热更新。
class MemoryIndex extends ChangeNotifier {
  final Map<String, LogRecord> _records = {};

  int get totalLineCount => _scannedLines;
  int _scannedLines = 0;

  int get activeCount => _records.length;

  /// 总行数 / 有效记录数 ≥ ratio 时建议 compact。
  double get amplification =>
      _records.isEmpty ? 0 : _scannedLines / _records.length;

  Iterable<LogRecord> get activeRecords => _records.values;

  /// 全部活记录，按更新时间倒序（最新在前），用于列表默认展示。
  List<LogRecord> get recordsByUpdatedDesc {
    final out = _records.values.toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
    return out;
  }

  /// 用日志记录 replay 出最新状态。同 id 后写覆盖前写；DEL 移除。
  void replay(List<LogRecord> log) {
    _records.clear();
    _scannedLines = log.length;
    for (final r in log) {
      switch (r.op) {
        case LogOp.add:
        case LogOp.update:
          _records[r.id] = r;
        case LogOp.delete:
          _records.remove(r.id);
      }
    }
    notifyListeners();
  }

  /// 把一条新追加的日志应用到内存（不重置扫描计数）。
  void apply(LogRecord r) {
    _scannedLines += 1;
    switch (r.op) {
      case LogOp.add:
      case LogOp.update:
        _records[r.id] = r;
      case LogOp.delete:
        _records.remove(r.id);
    }
    notifyListeners();
  }

  /// 全文检索：把查询串按空白拆词，要求每个词都出现在 标题 或 正文 里
  /// （大小写不敏感）。空查询返回全部（按更新时间倒序）。
  List<LogRecord> search(String query) {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) return recordsByUpdatedDesc;
    final out = <LogRecord>[];
    for (final r in recordsByUpdatedDesc) {
      final haystack = '${r.title ?? ''}\n${r.body ?? ''}'.toLowerCase();
      if (terms.every(haystack.contains)) {
        out.add(r);
      }
    }
    return out;
  }

  /// 给定 record_id 查找当前活记录，找不到返回 null。
  LogRecord? get(String id) => _records[id];
}
