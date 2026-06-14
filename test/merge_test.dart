import 'package:flutter_test/flutter_test.dart';
import 'package:syncpad/models/note.dart';
import 'package:syncpad/storage/conflict_merger.dart';

void main() {
  group('conflict_merger', () {
    LogRecord add(String id, int ts, String t) => LogRecord(
          op: LogOp.add,
          id: id,
          ts: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
          title: t,
          body: 'body',
        );
    LogRecord upd(String id, int ts, String t) => LogRecord(
          op: LogOp.update,
          id: id,
          ts: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
          title: t,
          body: 'body',
        );
    LogRecord del(String id, int ts) => LogRecord(
          op: LogOp.delete,
          id: id,
          ts: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
        );

    test('union 两端独立 id', () {
      final merged = mergeLogs([add('a', 1, 'A')], [add('b', 2, 'B')]);
      expect(merged.length, 2);
    });

    test('同 id 取 ts 更大（后写胜出）', () {
      final merged = mergeLogs([add('a', 1, '旧标题')], [upd('a', 2, '新标题')]);
      expect(merged.single.title, '新标题');
    });

    test('同 ts 时 DEL 胜出', () {
      final merged = mergeLogs([upd('a', 5, 'x')], [del('a', 5)]);
      expect(merged.single.op, LogOp.delete);
    });

    test('输出按时间升序', () {
      final merged = mergeLogs(
        [add('b', 3, 'b'), add('a', 1, 'a')],
        [add('c', 2, 'c')],
      );
      expect(merged.map((r) => r.id).toList(), ['a', 'c', 'b']);
    });
  });

  group('LogRecord 序列化 roundtrip', () {
    test('ADD 带标题/正文（含换行与中文）能往返', () {
      final r = LogRecord(
        op: LogOp.add,
        id: 'x1',
        ts: DateTime.fromMillisecondsSinceEpoch(1715000000 * 1000, isUtc: true),
        title: '会议纪要',
        body: '第一行\n第二行 🔖',
      );
      final back = LogRecord.fromLine(r.toLine());
      expect(back.op, LogOp.add);
      expect(back.id, 'x1');
      expect(back.title, '会议纪要');
      expect(back.body, '第一行\n第二行 🔖');
      expect(back.ts, r.ts);
    });

    test('DEL 不带正文字段', () {
      final r = LogRecord(
        op: LogOp.delete,
        id: 'x2',
        ts: DateTime.fromMillisecondsSinceEpoch(1715000001 * 1000, isUtc: true),
      );
      final line = r.toLine();
      expect(line.contains('"b"'), isFalse);
      final back = LogRecord.fromLine(line);
      expect(back.op, LogOp.delete);
      expect(back.id, 'x2');
    });
  });
}
