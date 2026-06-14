import 'dart:convert';

/// 条目类型：普通笔记 / 待办（清单）。
enum NoteKind { note, todo }

/// 待办里的一个清单项。
class ChecklistItem {
  final String text;
  final bool done;
  const ChecklistItem({required this.text, this.done = false});

  ChecklistItem copyWith({String? text, bool? done}) =>
      ChecklistItem(text: text ?? this.text, done: done ?? this.done);

  Map<String, Object?> toJson() => {'t': text, 'd': done};

  static ChecklistItem fromJson(Map<String, dynamic> j) => ChecklistItem(
        text: j['t'] as String? ?? '',
        done: j['d'] as bool? ?? false,
      );
}

/// UI 面向的"一条活记录"视图，由最新的 [LogRecord] 推导而来。
class Note {
  final String id;
  final NoteKind kind;
  final String title;
  final String body; // 仅 note 类型
  final List<ChecklistItem> items; // 仅 todo 类型
  final int color; // 调色板索引，0 = 默认
  final bool pinned;
  final String folder; // '' = 未分类
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt; // 非 null = 在回收站

  const Note({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.items,
    required this.color,
    required this.pinned,
    required this.folder,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  bool get isTodo => kind == NoteKind.todo;
  bool get isDeleted => deletedAt != null;

  int get doneCount => items.where((i) => i.done).length;
  int get totalCount => items.length;

  /// 待办整体是否完成：有子项时取"全部子项完成"，否则看自身（单行待办用 items=[1 项]）。
  bool get allDone => items.isNotEmpty && doneCount == totalCount;

  /// 列表预览：笔记取正文首行；待办取首个未完成项。最多 120 字。
  String get preview {
    final source = isTodo
        ? (items.isEmpty
            ? ''
            : (items.firstWhere((i) => !i.done, orElse: () => items.first))
                .text)
        : body;
    final firstLine = source
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return firstLine.length > 120 ? firstLine.substring(0, 120) : firstLine;
  }

  static Note fromRecord(LogRecord r) => Note(
        id: r.id,
        kind: r.kind,
        title: r.title ?? '',
        body: r.body ?? '',
        items: r.items,
        color: r.color,
        pinned: r.pinned,
        folder: r.folder,
        createdAt: r.createdAt ?? r.ts,
        updatedAt: r.ts,
        deletedAt: r.deletedAt,
      );
}

/// 日志中的一行：操作类型 + record_id + 时间戳 + 载荷字段（行式 JSON）。
///
/// 物理格式举例：
///   {"op":"ADD","id":"..","ts":1715000000,"cr":1715000000,"k":"note","t":"标题","b":"正文","c":2,"pin":true,"f":"工作"}
///   {"op":"UPD","id":"..","ts":1715000100,"k":"todo","t":"买菜","items":[{"t":"鸡蛋","d":false}]}
///   {"op":"UPD","id":"..","ts":1715000200,"del":1715000200}   // 移入回收站
///   {"op":"DEL","id":"..","ts":1715000300}                    // 彻底删除（tombstone）
///
/// append-only：每次改动追加一行；同 id 后写覆盖前写；DEL 物理移除。
/// 字段全部可选、缺省有合理默认，向后兼容（老的纯笔记日志能直接读）。
enum LogOp { add, update, delete }

class LogRecord {
  final LogOp op;
  final String id;
  final DateTime ts;
  final NoteKind kind;
  final String? title;
  final String? body;
  final List<ChecklistItem> items;
  final int color;
  final bool pinned;
  final String folder;
  final DateTime? createdAt;
  final DateTime? deletedAt;

  const LogRecord({
    required this.op,
    required this.id,
    required this.ts,
    this.kind = NoteKind.note,
    this.title,
    this.body,
    this.items = const [],
    this.color = 0,
    this.pinned = false,
    this.folder = '',
    this.createdAt,
    this.deletedAt,
  });

  static int _secs(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ 1000;
  static DateTime _fromSecs(int s) =>
      DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);

  String toLine() {
    final m = <String, Object?>{
      'op': switch (op) {
        LogOp.add => 'ADD',
        LogOp.update => 'UPD',
        LogOp.delete => 'DEL',
      },
      'id': id,
      'ts': _secs(ts),
    };
    if (op != LogOp.delete) {
      m['k'] = kind.name;
      m['t'] = title ?? '';
      if (kind == NoteKind.todo) {
        m['items'] = items.map((e) => e.toJson()).toList();
      } else {
        m['b'] = body ?? '';
      }
      if (color != 0) m['c'] = color;
      if (pinned) m['pin'] = true;
      if (folder.isNotEmpty) m['f'] = folder;
      if (createdAt != null) m['cr'] = _secs(createdAt!);
      if (deletedAt != null) m['del'] = _secs(deletedAt!);
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
    final rawItems = m['items'];
    return LogRecord(
      op: op,
      id: m['id'] as String,
      ts: _fromSecs(m['ts'] as int),
      kind: (m['k'] as String?) == 'todo' ? NoteKind.todo : NoteKind.note,
      title: m['t'] as String?,
      body: m['b'] as String?,
      items: rawItems is List
          ? rawItems
              .map((e) => ChecklistItem.fromJson((e as Map).cast<String, dynamic>()))
              .toList()
          : const [],
      color: (m['c'] as num?)?.toInt() ?? 0,
      pinned: m['pin'] as bool? ?? false,
      folder: m['f'] as String? ?? '',
      createdAt: m['cr'] == null ? null : _fromSecs((m['cr'] as num).toInt()),
      deletedAt: m['del'] == null ? null : _fromSecs((m['del'] as num).toInt()),
    );
  }
}
