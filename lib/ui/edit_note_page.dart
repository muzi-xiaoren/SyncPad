import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// 笔记编辑页。[noteId] 为 null 表示新建。
/// 返回上一页时自动保存（空笔记不创建；无变化不写日志）。
class EditNotePage extends StatefulWidget {
  const EditNotePage({super.key, this.noteId});

  final String? noteId;

  @override
  State<EditNotePage> createState() => _EditNotePageState();
}

class _EditNotePageState extends State<EditNotePage> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String? _noteId;

  @override
  void initState() {
    super.initState();
    _noteId = widget.noteId;
    final app = context.read<AppState>();
    if (_noteId != null) {
      final note = app.repo.getNote(_noteId!);
      if (note != null) {
        _title.text = note.title;
        _body.text = note.body;
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final title = _title.text.trim();
    final body = _body.text;
    if (_noteId == null) {
      if (title.isEmpty && body.trim().isEmpty) return; // 空笔记不创建
      _noteId = await app.repo.add(title: title, body: body);
      await app.maybePushAfterEdit('add note');
    } else {
      final cur = app.repo.getNote(_noteId!);
      if (cur == null) return;
      if (cur.title == title && cur.body == body) return; // 无变化
      await app.repo.update(id: _noteId!, title: title, body: body);
      await app.maybePushAfterEdit('update note');
    }
  }

  Future<void> _delete() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final id = _noteId;
    if (id == null) {
      nav.pop();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: const Text('确定删除这条笔记吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await app.repo.deleteById(id);
    await app.maybePushAfterEdit('delete note');
    _noteId = null; // 阻止 PopScope 再次保存
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        await _save();
        nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.noteId == null ? '新建笔记' : '编辑笔记'),
          actions: [
            if (widget.noteId != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除',
                onPressed: _delete,
              ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                textInputAction: TextInputAction.next,
                style: Theme.of(context).textTheme.titleLarge,
                decoration: const InputDecoration(
                  hintText: '标题',
                  border: InputBorder.none,
                ),
              ),
              const Divider(),
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
