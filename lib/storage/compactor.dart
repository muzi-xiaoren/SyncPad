import '../models/note.dart';
import 'log_store.dart';
import 'memory_index.dart';

/// 压实策略（与 PassPro 一致）：
///   - 把内存里的活记录全部转成一行 ADD 写出
///   - 写到 tmp 文件再原子 rename 替换原日志
///   - 之后重新 replay 索引
class Compactor {
  Compactor(this.store, this.index);

  final LogStore store;
  final MemoryIndex index;

  /// 默认放大率阈值 3：总行数 ≥ 活记录数 × 3 时建议 compact。
  static const double defaultAmplificationThreshold = 3.0;

  bool shouldCompact({
    double ratioThreshold = defaultAmplificationThreshold,
    int minLines = 50,
  }) {
    if (index.totalLineCount < minLines) return false;
    return index.amplification >= ratioThreshold;
  }

  /// 同步阶段约束："只在本地无待推变更且远端无未拉取变更"才允许调用。
  /// 该检查由调用方（SyncManager / UI）负责。
  Future<CompactionReport> compact() async {
    final before = await store.sizeBytes();
    final active = index.activeRecords.toList(growable: false);
    final snapshot = active.map((r) => LogRecord(
          op: LogOp.add,
          id: r.id,
          ts: r.ts,
          kind: r.kind,
          title: r.title,
          body: r.body,
          items: r.items,
          color: r.color,
          pinned: r.pinned,
          folder: r.folder,
          createdAt: r.createdAt ?? r.ts,
          deletedAt: r.deletedAt,
        ));
    await store.replaceAll(snapshot);
    index.replay(await store.readAll());
    final after = await store.sizeBytes();
    return CompactionReport(
      beforeBytes: before,
      afterBytes: after,
      activeRecords: active.length,
    );
  }
}

class CompactionReport {
  final int beforeBytes;
  final int afterBytes;
  final int activeRecords;

  const CompactionReport({
    required this.beforeBytes,
    required this.afterBytes,
    required this.activeRecords,
  });

  int get savedBytes => beforeBytes - afterBytes;
}
