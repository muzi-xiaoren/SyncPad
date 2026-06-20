import 'package:flutter/foundation.dart';

import '../models/note.dart';
import '../settings/app_settings.dart';
import 'markdown_refs.dart';

/// 内存里的"活记录"索引：record_id → 最新一条 [LogRecord]（含软删除项）。
/// 启动时由 [replay] 一次性扫日志构建；之后所有 CRUD 都直接动它。
///
/// 软删除（回收站）的记录仍留在索引里（带 deletedAt），只有 DEL（彻底删）才移除。
/// 是 [ChangeNotifier]：任何写操作后通知监听者，列表/编辑界面自动热更新。
class MemoryIndex extends ChangeNotifier {
  final Map<String, LogRecord> _records = {};

  int get totalLineCount => _scannedLines;
  int _scannedLines = 0;

  /// 日志里活记录条数（含软删除），用于压实放大率。
  int get activeCount => _records.length;

  double get amplification =>
      _records.isEmpty ? 0 : _scannedLines / _records.length;

  Iterable<LogRecord> get activeRecords => _records.values;

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

  LogRecord? get(String id) => _records[id];
  Note? getNote(String id) {
    final r = _records[id];
    return r == null ? null : Note.fromRecord(r);
  }

  Iterable<Note> get _allNotes => _records.values.map(Note.fromRecord);

  /// 某类型的未删除条目（可选按文件夹过滤），按 [sort] 排序（置顶优先）。
  List<Note> byKind(
    NoteKind kind, {
    String? folder,
    NoteSort sort = NoteSort.updatedDesc,
  }) {
    final out = _allNotes
        .where((n) => n.kind == kind && !n.isDeleted)
        .where((n) => folder == null || folder.isEmpty || n.folder == folder)
        .toList()
      ..sort((a, b) => _cmp(a, b, sort));
    return out;
  }

  /// 检索某类型的未删除条目（标题 + 正文/清单项，全词命中、大小写不敏感）。
  List<Note> search(
    String query, {
    required NoteKind kind,
    String? folder,
    NoteSort sort = NoteSort.updatedDesc,
  }) {
    final base = byKind(kind, folder: folder, sort: sort);
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (terms.isEmpty) return base;
    return base.where((n) {
      final haystack = StringBuffer(n.title)
        ..write('\n')
        ..write(n.body);
      for (final it in n.items) {
        haystack
          ..write('\n')
          ..write(it.text);
      }
      final hay = haystack.toString().toLowerCase();
      return terms.every(hay.contains);
    }).toList();
  }

  /// 回收站：所有软删除条目，按删除时间倒序。
  List<Note> trashed() {
    final out = _allNotes.where((n) => n.isDeleted).toList()
      ..sort((a, b) => (b.deletedAt ?? b.updatedAt)
          .compareTo(a.deletedAt ?? a.updatedAt));
    return out;
  }

  /// 回收站里删除时间早于 [cutoff] 的条目 id（用于 30 天自动清理）。
  List<String> expiredTrash(DateTime cutoff) => trashed()
      .where((n) => (n.deletedAt ?? n.updatedAt).isBefore(cutoff))
      .map((n) => n.id)
      .toList();

  /// 全部未删除条目里出现过的文件夹名（去重、排序）。
  List<String> folders() {
    final set = <String>{};
    for (final n in _allNotes) {
      if (!n.isDeleted && n.folder.isNotEmpty) set.add(n.folder);
    }
    final out = set.toList()..sort();
    return out;
  }

  int countInFolder(NoteKind kind, String? folder) =>
      byKind(kind, folder: folder).length;

  int get trashCount => _allNotes.where((n) => n.isDeleted).length;

  /// 所有活记录（含回收站）正文里引用到的附件文件名（去重）。
  /// 同步时据此把缺失附件补齐到 / 从远端。
  Set<String> allAttachmentNames() {
    final out = <String>{};
    for (final r in _records.values) {
      final b = r.body;
      if (b != null && b.isNotEmpty) out.addAll(attachmentNamesIn(b));
    }
    return out;
  }

  static int _cmp(Note a, Note b, NoteSort sort) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return switch (sort) {
      NoteSort.updatedDesc => b.updatedAt.compareTo(a.updatedAt),
      NoteSort.createdDesc => b.createdAt.compareTo(a.createdAt),
      NoteSort.titleAsc =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    };
  }
}
