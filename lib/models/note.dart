import 'dart:convert';

/// 内存里的一条笔记。
class Note {
  final String id;
  final String title;
  final String body;
  final DateTime updatedAt;

  const Note({
    required this.id,
    required this.title,
    required this.body,
    required this.updatedAt,
  });

  /// 列表里展示用的副标题：正文首行（去掉空白），最多 80 字。
  String get preview {
    final firstLine = body
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return firstLine.length > 80 ? firstLine.substring(0, 80) : firstLine;
  }

  Note copyWith({
    String? title,
    String? body,
    DateTime? updatedAt,
  }) {
    return Note(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 日志中的一行：操作类型 + record_id + 时间戳 + title/body。
///
/// 物理格式（行式 JSON，便于 git diff 与冲突合并）：
///   {"op":"ADD","id":"...","ts":1715000000,"t":"标题","b":"正文"}
///   {"op":"UPD","id":"...","ts":1715000001,"t":"新标题","b":"新正文"}
///   {"op":"DEL","id":"...","ts":1715000002}
///
/// 设计取舍（与 PassPro 一致）：append-only 行式日志 + 内存索引，CRUD O(1)，
/// 启动一次性 replay；同步只是把这个文件在多端之间合并。
/// v0.1 笔记内容明文存储在你的私有仓库里；端到端加密为下一里程碑（届时把 PassPro
/// 的 FernetCrypto 搬过来对 body 加密即可，日志格式不变，仅 b 字段变密文）。
enum LogOp { add, update, delete }

class LogRecord {
  final LogOp op;
  final String id;
  final DateTime ts;
  final String? title;
  final String? body;

  const LogRecord({
    required this.op,
    required this.id,
    required this.ts,
    this.title,
    this.body,
  });

  String toLine() {
    final m = <String, Object?>{
      'op': switch (op) {
        LogOp.add => 'ADD',
        LogOp.update => 'UPD',
        LogOp.delete => 'DEL',
      },
      'id': id,
      'ts': ts.toUtc().millisecondsSinceEpoch ~/ 1000,
    };
    if (op != LogOp.delete) {
      m['t'] = title ?? '';
      m['b'] = body ?? '';
    }
    return jsonEncode(m);
  }

  static LogRecord fromLine(String line) {
    final m = jsonDecode(line) as Map<String, dynamic>;
    final op = switch (m['op'] as String) {
      'ADD' => LogOp.add,
      'UPD' => LogOp.update,
      'DEL' => LogOp.delete,
      final other => throw FormatException('未知 op: $other'),
    };
    return LogRecord(
      op: op,
      id: m['id'] as String,
      ts: DateTime.fromMillisecondsSinceEpoch(
        (m['ts'] as int) * 1000,
        isUtc: true,
      ),
      title: m['t'] as String?,
      body: m['b'] as String?,
    );
  }
}
