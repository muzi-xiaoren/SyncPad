import 'package:flutter_test/flutter_test.dart';
import 'package:syncpad/models/note.dart';
import 'package:syncpad/settings/app_settings.dart';
import 'package:syncpad/storage/memory_index.dart';

DateTime _t(int s) =>
    DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);

LogRecord _note(
  String id,
  int ts,
  String title,
  String body, {
  bool pinned = false,
  String folder = '',
  int? deletedTs,
}) =>
    LogRecord(
      op: LogOp.add,
      id: id,
      ts: _t(ts),
      kind: NoteKind.note,
      title: title,
      body: body,
      pinned: pinned,
      folder: folder,
      createdAt: _t(ts),
      deletedAt: deletedTs == null ? null : _t(deletedTs),
    );

LogRecord _todo(String id, int ts, String title, List<String> items) =>
    LogRecord(
      op: LogOp.add,
      id: id,
      ts: _t(ts),
      kind: NoteKind.todo,
      title: title,
      items: items.map((t) => ChecklistItem(text: t)).toList(),
      createdAt: _t(ts),
    );

void main() {
  group('MemoryIndex', () {
    test('replay：DEL 移除、UPD 覆盖', () {
      final ix = MemoryIndex()
        ..replay([
          _note('a', 1, '购物', '牛奶'),
          _note('b', 2, '草稿', 'x'),
          LogRecord(op: LogOp.delete, id: 'b', ts: _t(3)),
        ]);
      expect(ix.byKind(NoteKind.note).length, 1);
      expect(ix.getNote('a')?.title, '购物');
      expect(ix.getNote('b'), isNull);
    });

    test('byKind 区分 note/todo，且置顶优先于时间', () {
      final ix = MemoryIndex()
        ..replay([
          _note('a', 5, 'A', ''), // 较新但未置顶
          _note('b', 2, 'B', '', pinned: true), // 较旧但置顶
          _todo('c', 3, '待办', ['x']),
        ]);
      expect(ix.byKind(NoteKind.note, sort: NoteSort.updatedDesc).map((n) => n.id),
          ['b', 'a']);
      expect(ix.byKind(NoteKind.todo).map((n) => n.id), ['c']);
    });

    test('search 跨标题/正文/清单项，且限定类型', () {
      final ix = MemoryIndex()
        ..replay([
          _note('a', 1, 'Flutter 笔记', 'Provider 状态管理'),
          _note('b', 2, '购物', '牛奶 鸡蛋'),
          _todo('c', 3, '喝水', ['多喝热水']),
        ]);
      expect(ix.search('flutter', kind: NoteKind.note).map((n) => n.id), ['a']);
      expect(ix.search('鸡蛋', kind: NoteKind.note).map((n) => n.id), ['b']);
      expect(ix.search('热水', kind: NoteKind.todo).map((n) => n.id), ['c']);
      expect(ix.search('', kind: NoteKind.note).length, 2);
    });

    test('软删除进回收站，不出现在 byKind', () {
      final ix = MemoryIndex()
        ..replay([
          _note('a', 1, 'A', '', deletedTs: 2),
          _note('b', 1, 'B', ''),
        ]);
      expect(ix.byKind(NoteKind.note).map((n) => n.id), ['b']);
      expect(ix.trashed().map((n) => n.id), ['a']);
      expect(ix.trashCount, 1);
    });

    test('expiredTrash 找出删除超期的条目', () {
      final ix = MemoryIndex()
        ..replay([
          _note('old', 1, '旧', '', deletedTs: 1000), // 删除于 t=1000
          _note('mid', 2, '中', '', deletedTs: 5000), // 删除于 t=5000
          _note('live', 3, '活', ''), // 未删除，不计
        ]);
      expect(ix.expiredTrash(_t(4000)), ['old']); // 仅 old 早于 cutoff
      expect(ix.expiredTrash(_t(900)), isEmpty); // 都未超期
      expect(ix.expiredTrash(_t(6000)).toSet(), {'old', 'mid'});
    });

    test('folders 去重、排序、排除未分类', () {
      final ix = MemoryIndex()
        ..replay([
          _note('a', 1, 'A', '', folder: '工作'),
          _note('b', 2, 'B', '', folder: '生活'),
          _note('c', 3, 'C', ''),
        ]);
      expect(ix.folders(), ['工作', '生活']);
      expect(ix.byKind(NoteKind.note, folder: '工作').map((n) => n.id), ['a']);
    });
  });
}
