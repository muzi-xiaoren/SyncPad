import '../models/note.dart';

/// 把本地和远端两份日志按 record_id 做行级 union：
///   - 同 id 取 ts 较大的那条（"后写胜出"——同一篇笔记在两端都改过时，较晚的编辑赢）
///   - DEL 永远胜过同 ts 的非 DEL（保证删除最终成立）
///   - 输出按 ts 升序排列，方便 replay
///
/// 注意：这是"每篇笔记"粒度的合并，不是"段落/字符"粒度。两端同时改同一篇笔记，
/// 较早那次编辑会被覆盖（不会损坏数据，但会丢一次改动）。真正的并发文本合并
/// 需要 CRDT（Yjs/Automerge），列为后续里程碑。
List<LogRecord> mergeLogs(List<LogRecord> a, List<LogRecord> b) {
  final byId = <String, LogRecord>{};
  void consider(LogRecord r) {
    final cur = byId[r.id];
    if (cur == null) {
      byId[r.id] = r;
      return;
    }
    if (r.ts.isAfter(cur.ts)) {
      byId[r.id] = r;
    } else if (r.ts == cur.ts &&
        r.op == LogOp.delete &&
        cur.op != LogOp.delete) {
      byId[r.id] = r;
    }
  }

  for (final r in a) {
    consider(r);
  }
  for (final r in b) {
    consider(r);
  }

  final out = byId.values.toList()
    ..sort((x, y) => x.ts.compareTo(y.ts));
  return out;
}
