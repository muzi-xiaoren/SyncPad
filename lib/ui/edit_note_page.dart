import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'note_actions.dart';
import 'note_palette.dart';

/// 笔记编辑页。[noteId] 为 null 表示新建（可带 [initialFolder]）。
/// 返回时自动保存（空笔记不创建；无变化不写日志）。
class EditNotePage extends StatefulWidget {
  const EditNotePage({super.key, this.noteId, this.initialFolder = ''});

  final String? noteId;
  final String initialFolder;

  @override
  State<EditNotePage> createState() => _EditNotePageState();
}

class _EditNotePageState extends State<EditNotePage> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String? _noteId;
  int _color = 0;
  bool _pinned = false;
  String _folder = '';

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
        _body.text = note.body;
        _color = note.color;
        _pinned = note.pinned;
        _folder = note.folder;
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _isEmpty => _title.text.trim().isEmpty && _body.text.trim().isEmpty;

  Future<void> _save() async {
    final app = context.read<AppState>();
    final title = _title.text.trim();
    final body = _body.text;
    if (_noteId == null) {
      if (_isEmpty) return;
      final id = await app.repo
          .addNote(title: title, body: body, color: _color, folder: _folder);
      _noteId = id;
      if (_pinned) await app.repo.setPinned(id, true);
      await app.maybePushAfterEdit('add note');
    } else {
      final cur = app.repo.getNote(_noteId!);
      if (cur == null) return;
      if (cur.title != title || cur.body != body) {
        await app.repo.updateNote(id: _noteId!, title: title, body: body);
        await app.maybePushAfterEdit('update note');
      }
    }
  }

  // 颜色/置顶/文件夹：已保存的笔记即时写入；未保存的先存到本地状态，保存时一并落库。
  Future<void> _pickColor() async {
    final app = context.read<AppState>();
    final picked = await pickColorIndex(context, _color);
    if (picked == null) return;
    setState(() => _color = picked);
    if (_noteId != null) {
      await app.repo.setColor(_noteId!, picked);
      await app.maybePushAfterEdit('color note');
    }
  }

  Future<void> _togglePin() async {
    final app = context.read<AppState>();
    setState(() => _pinned = !_pinned);
    if (_noteId != null) {
      await app.repo.setPinned(_noteId!, _pinned);
      await app.maybePushAfterEdit('pin note');
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
      await app.maybePushAfterEdit('move note');
    }
  }

  Future<void> _delete() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    if (_noteId == null) {
      nav.pop();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final id = _noteId!;
    await app.repo.moveToTrash(id);
    await app.maybePushAfterEdit('trash note');
    _noteId = null; // 阻止 PopScope 再次保存
    nav.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('已移到回收站'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await app.repo.restore(id);
            await app.maybePushAfterEdit('undo trash');
          },
        ),
      ));
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
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                textInputAction: TextInputAction.next,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  hintText: '标题',
                  border: InputBorder.none,
                ),
              ),
              const Divider(height: 8),
              Expanded(
                child: TextField(
                  controller: _body,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: '在这里写点什么…',
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
