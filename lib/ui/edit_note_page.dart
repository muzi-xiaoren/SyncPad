import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../settings/app_settings.dart';
import 'block_editor.dart';
import 'markdown_view.dart';
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
  final _bodyFocus = FocusNode();
  final _previewFocus = FocusNode(); // 全屏预览时接收 Esc 快捷键
  final _blockKey = GlobalKey<BlockEditorState>(); // 块级编辑器（实时预览模式）
  String? _noteId;
  int _color = 0;
  bool _pinned = false;
  String _folder = '';
  bool _preview = false;

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
    _bodyFocus.dispose();
    _previewFocus.dispose();
    super.dispose();
  }

  /// 切换编辑/预览（普通模式）或 所见即所得/整篇源码（实时预览模式）。
  void _togglePreview() {
    // 从块级编辑切到源码前，先提交正在编辑的块，保证源码是最新的。
    _blockKey.currentState?.commitPending();
    setState(() => _preview = !_preview);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_preview ? _previewFocus : _bodyFocus).requestFocus();
    });
  }

  /// 块级编辑器写回 _body 后：保存并触发同步。
  void _onBlockCommit() {
    // ignore: discarded_futures
    _save();
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

  /// 选一张本地图片，降采样后存进附件仓，插入 Markdown 引用。
  Future<void> _insertImage() async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    final picked =
        await FilePicker.pickFiles(type: FileType.image, withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;
    final ref = await app.attachments.add(bytes, sourceExt: file.extension);
    if (!mounted) return;

    final blockState = _blockKey.currentState;
    if (blockState != null) {
      // 块级编辑器：追加一张图片块（内部已写回 _body 并触发保存）。
      blockState.insertImageRef(ref);
    } else {
      // 文本框：在光标处插入引用。
      final text = _body.text;
      final sel = _body.selection;
      final at = (sel.isValid && sel.start >= 0 && sel.start <= text.length)
          ? sel.start
          : text.length;
      final end = (sel.isValid && sel.end >= at && sel.end <= text.length)
          ? sel.end
          : at;
      final pre = (at > 0 && text[at - 1] != '\n') ? '\n' : '';
      final insert = '$pre![]($ref)\n';
      final newText = text.replaceRange(at, end, insert);
      _body.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: at + insert.length),
      );
      await _save(); // 图片已入仓，把引用落库（并触发同步）
    }
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('已插入图片')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.read<AppState>();
    final live = context.watch<AppSettings>().livePreview;
    final bg = NotePalette.background(_color, theme.brightness);

    // 快捷键：⌘/Ctrl+P 在任意位置切换预览（带修饰键，不与文本输入冲突）；
    // 全屏预览中（无输入框聚焦）再额外支持 Esc 退回编辑。
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyP, control: true):
          _togglePreview,
      const SingleActivator(LogicalKeyboardKey.keyP, meta: true):
          _togglePreview,
    };
    if (_preview && !live) {
      bindings[const SingleActivator(LogicalKeyboardKey.escape)] =
          _togglePreview;
    }

    final Widget body;
    if (live) {
      // 实时预览(B)：默认块级所见即所得；⌘/Ctrl+P 切「整篇源码」逃生口。
      body = _preview ? _editorBody(theme) : _blockBody(theme, app);
    } else if (_preview) {
      body = Focus(
        focusNode: _previewFocus,
        child: _previewPane(theme, app),
      );
    } else {
      body = _editorBody(theme);
    }

    return CallbackShortcuts(
      bindings: bindings,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final nav = Navigator.of(context);
          _blockKey.currentState?.commitPending(); // 提交块级编辑器待写入内容
          await _save();
          nav.pop();
        },
        child: Scaffold(
          backgroundColor: bg,
          appBar: AppBar(
            backgroundColor: bg,
            actions: [
              // 普通模式：编辑⇄预览；实时预览(B)模式：所见即所得⇄整篇源码。
              IconButton(
                tooltip: live
                    ? (_preview ? '所见即所得 (⌘/Ctrl+P)' : '整篇源码 (⌘/Ctrl+P)')
                    : (_preview ? '编辑 (⌘/Ctrl+P)' : '预览 (⌘/Ctrl+P)'),
                icon: Icon(live
                    ? (_preview ? Icons.article_outlined : Icons.code)
                    : (_preview
                        ? Icons.edit_outlined
                        : Icons.visibility_outlined)),
                onPressed: _togglePreview,
              ),
              if (live || !_preview)
                IconButton(
                  tooltip: '插入图片',
                  icon: const Icon(Icons.image_outlined),
                  onPressed: _insertImage,
                ),
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
          body: body,
        ),
      ),
    );
  }

  /// 全屏编辑：标题 + 正文输入框（也用作实时预览模式的「整篇源码」）。
  Widget _editorBody(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: _editorColumn(theme),
      );

  Widget _editorColumn(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _titleField(theme),
          const Divider(height: 8),
          Expanded(
            child: TextField(
              controller: _body,
              focusNode: _bodyFocus,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: '在这里写点什么…（支持 Markdown）',
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      );

  Widget _titleField(ThemeData theme) => TextField(
        controller: _title,
        textInputAction: TextInputAction.next,
        style:
            theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        decoration: const InputDecoration(
          hintText: '标题',
          border: InputBorder.none,
        ),
      );

  /// 实时预览(B)：标题 + 块级所见即所得编辑器。
  Widget _blockBody(ThemeData theme, AppState app) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: _titleField(theme),
          ),
          const Divider(height: 8),
          Expanded(
            child: BlockEditor(
              key: _blockKey,
              body: _body,
              attachments: app.attachments,
              onCommit: _onBlockCommit,
            ),
          ),
        ],
      );

  /// 全屏渲染预览（普通模式 ⌘/Ctrl+P）。
  Widget _previewPane(ThemeData theme, AppState app) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (_title.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_title.text,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
          MarkdownView(data: _body.text, attachments: app.attachments),
        ],
      );
}
