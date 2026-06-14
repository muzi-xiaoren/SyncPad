import '../models/note.dart';
import 'log_store.dart';
import 'memory_index.dart';

/// 业务层入口：把 [LogStore] + [MemoryIndex] 拼成 CRUD API。
/// UI 只跟这个类打交道。
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

  /// 新建一条笔记，返回新记录的 id。
  Future<String> add({required String title, required String body}) async {
    final record = LogRecord(
      op: LogOp.add,
      id: _newId(),
      ts: DateTime.now().toUtc(),
      title: title,
      body: body,
    );
    await store.append(record);
    index.apply(record);
    return record.id;
  }

  /// 更新一条（按 id）。
  Future<void> update({
    required String id,
    String? title,
    String? body,
  }) async {
    final current = index.get(id);
    if (current == null) {
      throw StateError('note $id 不存在');
    }
    final record = LogRecord(
      op: LogOp.update,
      id: id,
      ts: DateTime.now().toUtc(),
      title: title ?? current.title,
      body: body ?? current.body,
    );
    await store.append(record);
    index.apply(record);
  }

  /// 按 record_id 删除（写 tombstone）。
  Future<void> deleteById(String id) async {
    if (index.get(id) == null) {
      throw StateError('note $id 不存在');
    }
    final record = LogRecord(
      op: LogOp.delete,
      id: id,
      ts: DateTime.now().toUtc(),
    );
    await store.append(record);
    index.apply(record);
  }

  /// 取一条活记录并转成 [Note]，找不到返回 null。
  Note? getNote(String id) {
    final r = index.get(id);
    if (r == null) return null;
    return _toNote(r);
  }

  /// 检索（空查询返回全部，按更新时间倒序）。
  List<Note> search(String query) =>
      index.search(query).map(_toNote).toList(growable: false);

  static Note _toNote(LogRecord r) => Note(
        id: r.id,
        title: r.title ?? '',
        body: r.body ?? '',
        updatedAt: r.ts,
      );

  static String _newId() {
    // 16 进制时间戳前缀 + 随机后缀，单设备内唯一。
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
    final rnd = (DateTime.now().microsecond * 1315423911) & 0x7FFFFFFF;
    return '$ts-${rnd.toRadixString(36)}';
  }
}
