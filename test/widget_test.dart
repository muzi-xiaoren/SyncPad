import 'package:flutter_test/flutter_test.dart';
import 'package:syncpad/models/note.dart';
import 'package:syncpad/storage/memory_index.dart';

void main() {
  LogRecord add(String id, int ts, String title, String body) => LogRecord(
        op: LogOp.add,
        id: id,
        ts: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
        title: title,
        body: body,
      );

  group('MemoryIndex', () {
    test('replay 后 DEL 移除、UPD 覆盖', () {
      final ix = MemoryIndex()
        ..replay([
          add('a', 1, '购物清单', '牛奶 鸡蛋'),
          add('b', 2, '待办', '写代码'),
          LogRecord(
              op: LogOp.delete,
              id: 'b',
              ts: DateTime.fromMillisecondsSinceEpoch(3 * 1000, isUtc: true)),
        ]);
      expect(ix.activeCount, 1);
      expect(ix.get('a')?.title, '购物清单');
      expect(ix.get('b'), isNull);
    });

    test('search 跨标题与正文、多词需全部命中、大小写不敏感', () {
      final ix = MemoryIndex()
        ..replay([
          add('a', 1, 'Flutter 笔记', '学习 Provider 状态管理'),
          add('b', 2, '购物', '牛奶 鸡蛋 面包'),
        ]);
      expect(ix.search('flutter').map((r) => r.id), ['a']);
      expect(ix.search('provider 状态').map((r) => r.id), ['a']);
      expect(ix.search('鸡蛋').map((r) => r.id), ['b']);
      expect(ix.search('不存在的词'), isEmpty);
      expect(ix.search('').length, 2); // 空查询返回全部
    });

    test('recordsByUpdatedDesc 按更新时间倒序', () {
      final ix = MemoryIndex()
        ..replay([
          add('a', 1, 'old', ''),
          add('b', 3, 'new', ''),
          add('c', 2, 'mid', ''),
        ]);
      expect(ix.recordsByUpdatedDesc.map((r) => r.id).toList(), ['b', 'c', 'a']);
    });
  });
}
