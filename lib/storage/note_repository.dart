import '../models/note.dart';
import 'log_store.dart';
import 'memory_index.dart';

/// 业务层入口：把 [LogStore] + [MemoryIndex] 拼成 CRUD API。UI 只跟这个类打交道。
///
/// 每个写操作都追加一条 ts=now 的新日志（append-only），保证在多端合并时"后写胜出"。
class NoteRepository {
  NoteRepository._(this.store, this.index);

  final LogStore store;
  final MemoryIndex index;

  static Future<NoteRepository> open() async {
    final store = await LogStore.open();
    final index = MemoryIndex();
    index.replay(await store.readAll());
    return NoteRepository._(store, index);
  }

  Future<void> _write(LogRecord r) async {
    await store.append(r);
    index.apply(r);
  }

  LogRecord _require(String id) {
    final cur = index.get(id);
    if (cur == null) throw StateError('记录 $id 不存在');
    return cur;
  }

  /// 取一条活记录的 [Note] 视图（含软删除项），找不到返回 null。
  Note? getNote(String id) => index.getNote(id);

  // ----- 新建 -----

  Future<String> addNote({
    String title = '',
    String body = '',
    int color = 0,
    String folder = '',
  }) async {
    final now = DateTime.now().toUtc();
    final r = LogRecord(
      op: LogOp.add,
      id: _newId(),
      ts: now,
      kind: NoteKind.note,
      title: title,
      body: body,
      color: color,
      folder: folder,
      createdAt: now,
    );
    await _write(r);
    return r.id;
  }

  Future<String> addTodo({
    String title = '',
    List<ChecklistItem> items = const [],
    int color = 0,
    String folder = '',
  }) async {
    final now = DateTime.now().toUtc();
    final r = LogRecord(
      op: LogOp.add,
      id: _newId(),
      ts: now,
      kind: NoteKind.todo,
      title: title,
      items: items.isEmpty ? const [ChecklistItem(text: '')] : items,
      color: color,
      folder: folder,
      createdAt: now,
    );
    await _write(r);
    return r.id;
  }

  // ----- 编辑（保留未改动字段）-----

  /// 基于现有记录打补丁，写一条新的 UPD（ts=now）。
  Future<void> _patch(
    String id, {
    String? title,
    String? body,
    List<ChecklistItem>? items,
    int? color,
    bool? pinned,
    String? folder,
    Object? deletedAt = _unset, // 传 null 可清除；不传则保留
  }) async {
    final cur = _require(id);
    await _write(LogRecord(
      op: LogOp.update,
      id: id,
      ts: DateTime.now().toUtc(),
      kind: cur.kind,
      title: title ?? cur.title,
      body: body ?? cur.body,
      items: items ?? cur.items,
      color: color ?? cur.color,
      pinned: pinned ?? cur.pinned,
      folder: folder ?? cur.folder,
      createdAt: cur.createdAt ?? cur.ts,
      deletedAt: identical(deletedAt, _unset)
          ? cur.deletedAt
          : deletedAt as DateTime?,
    ));
  }

  Future<void> updateNote({
    required String id,
    String? title,
    String? body,
  }) =>
      _patch(id, title: title, body: body);

  Future<void> updateTodo({
    required String id,
    String? title,
    List<ChecklistItem>? items,
  }) =>
      _patch(id, title: title, items: items);

  Future<void> setColor(String id, int color) => _patch(id, color: color);

  Future<void> setPinned(String id, bool pinned) => _patch(id, pinned: pinned);

  Future<void> togglePinned(String id) =>
      _patch(id, pinned: !_require(id).pinned);

  Future<void> setFolder(String id, String folder) =>
      _patch(id, folder: folder);

  /// 勾选/取消勾选待办的第 [itemIndex] 个清单项。
  Future<void> toggleTodoItem(String id, int itemIndex) async {
    final cur = _require(id);
    if (itemIndex < 0 || itemIndex >= cur.items.length) return;
    final items = [...cur.items];
    items[itemIndex] =
        items[itemIndex].copyWith(done: !items[itemIndex].done);
    await _patch(id, items: items);
  }

  // ----- 回收站 -----

  /// 移入回收站（软删除）。
  Future<void> moveToTrash(String id) =>
      _patch(id, deletedAt: DateTime.now().toUtc());

  /// 从回收站恢复。
  Future<void> restore(String id) => _patch(id, deletedAt: null);

  /// 彻底删除（写 tombstone，物理移除）。
  Future<void> deleteForever(String id) async {
    _require(id);
    await _write(LogRecord(
      op: LogOp.delete,
      id: id,
      ts: DateTime.now().toUtc(),
    ));
  }

  /// 清空回收站。
  Future<void> emptyTrash() async {
    for (final n in index.trashed()) {
      await deleteForever(n.id);
    }
  }

  static const Object _unset = Object();

  static String _newId() {
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
    final rnd = (DateTime.now().microsecond * 1315423911) & 0x7FFFFFFF;
    return '$ts-${rnd.toRadixString(36)}';
  }
}
