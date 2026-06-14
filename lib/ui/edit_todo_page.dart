import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import 'note_actions.dart';
import 'note_palette.dart';

/// 待办（清单）编辑页。[noteId] 为 null 表示新建。
class EditTodoPage extends StatefulWidget {
  const EditTodoPage({super.key, this.noteId, this.initialFolder = ''});

  final String? noteId;
  final String initialFolder;

  @override
  State<EditTodoPage> createState() => _EditTodoPageState();
}

class _TodoLine {
  _TodoLine(String text, this.done) : controller = TextEditingController(text: text);
  final TextEditingController controller;
  bool done;
}

class _EditTodoPageState extends State<EditTodoPage> {
  final _title = TextEditingController();
  final List<_TodoLine> _lines = [];
  String? _noteId;
  int _color = 0;
  bool _pinned = false;
  String _folder = '';
  late String _initialSnapshot;

  @override
  void initState() {
    super.initState();
    _noteId = widget.noteId;
    _folder = widget.initialFolder;
    final app = context.read<AppState>();
    if (_noteId != null) {
      final note = app.repo.getNote(_noteId!);
      if (note != null) {
        _title.text = note.title;
        _color = note.color;
        _pinned = note.pinned;
        _folder = note.folder;
        for (final it in note.items) {
          _lines.add(_TodoLine(it.text, it.done));
        }
      }
    }
    if (_lines.isEmpty) _lines.add(_TodoLine('', false));
    _initialSnapshot = _snapshot();
  }

  @override
  void dispose() {
    _title.dispose();
    for (final l in _lines) {
      l.controller.dispose();
    }
    super.dispose();
  }

  String _snapshot() {
    final sb = StringBuffer(_title.text.trim());
    for (final l in _lines) {
      sb.write('${l.done ? 1 : 0}:${l.controller.text.trim()}');
    }
    return sb.toString();
  }

  List<ChecklistItem> _collectItems() {
    final items = <ChecklistItem>[];
    for (final l in _lines) {
      final t = l.controller.text.trim();
      if (t.isEmpty) continue;
      items.add(ChecklistItem(text: t, done: l.done));
    }
    return items;
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final title = _title.text.trim();
    final items = _collectItems();
    if (_noteId == null) {
      if (title.isEmpty && items.isEmpty) return;
      final id = await app.repo.addTodo(
        title: title,
        items: items,
        color: _color,
        folder: _folder,
      );
      _noteId = id;
      if (_pinned) await app.repo.setPinned(id, true);
      await app.maybePushAfterEdit('add todo');
    } else {
      if (_snapshot() == _initialSnapshot) return; // 无变化
      await app.repo.updateTodo(id: _noteId!, title: title, items: items);
      await app.maybePushAfterEdit('update todo');
    }
  }

  Future<void> _pickColor() async {
    final app = context.read<AppState>();
    final picked = await pickColorIndex(context, _color);
    if (picked == null) return;
    setState(() => _color = picked);
    if (_noteId != null) {
      await app.repo.setColor(_noteId!, picked);
      await app.maybePushAfterEdit('color todo');
    }
  }

  Future<void> _togglePin() async {
    final app = context.read<AppState>();
    setState(() => _pinned = !_pinned);
    if (_noteId != null) {
      await app.repo.setPinned(_noteId!, _pinned);
      await app.maybePushAfterEdit('pin todo');
    }
  }

  Future<void> _pickFolder() async {
    final app = context.read<AppState>();
    final picked = await pickFolderName(context,
        current: _folder, folders: app.repo.index.folders());
    if (picked == null) return;
    setState(() => _folder = picked);
    if (_noteId != null) {
      await app.repo.setFolder(_noteId!, picked);
      await app.maybePushAfterEdit('move todo');
    }
  }

  Future<void> _delete() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    if (_noteId == null) {
      nav.pop();
      return;
    }
    await app.repo.moveToTrash(_noteId!);
    await app.maybePushAfterEdit('trash todo');
    _noteId = null;
    nav.pop();
  }

  void _addLine() {
    setState(() => _lines.add(_TodoLine('', false)));
  }

  void _removeLine(int i) {
    setState(() {
      _lines.removeAt(i).controller.dispose();
      if (_lines.isEmpty) _lines.add(_TodoLine('', false));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = NotePalette.background(_color, theme.brightness);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        await _save();
        nav.pop();
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          actions: [
            IconButton(
              tooltip: _pinned ? '取消置顶' : '置顶',
              icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
              onPressed: _togglePin,
            ),
            IconButton(
              tooltip: '颜色',
              icon: const Icon(Icons.palette_outlined),
              onPressed: _pickColor,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'folder') _pickFolder();
                if (v == 'delete') _delete();
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'folder',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(_folder.isEmpty ? '移动到文件夹' : '文件夹：$_folder'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
                controller: _title,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  hintText: '清单标题（可选）',
                  border: InputBorder.none,
                ),
              ),
            ),
            const Divider(height: 8),
            for (var i = 0; i < _lines.length; i++)
              Row(
                key: ObjectKey(_lines[i]),
                children: [
                  IconButton(
                    icon: Icon(
                      _lines[i].done
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      color: _lines[i].done
                          ? const Color(0xFFFFB300)
                          : theme.colorScheme.outline,
                    ),
                    onPressed: () =>
                        setState(() => _lines[i].done = !_lines[i].done),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _lines[i].controller,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => _addLine(),
                      style: TextStyle(
                        decoration: _lines[i].done
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                      decoration: const InputDecoration(
                        hintText: '清单项',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _removeLine(i),
                  ),
                ],
              ),
            TextButton.icon(
              onPressed: _addLine,
              icon: const Icon(Icons.add),
              label: const Text('添加一项'),
            ),
          ],
        ),
      ),
    );
  }
}
