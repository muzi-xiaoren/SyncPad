import 'package:flutter/material.dart';

import '../storage/attachment_store.dart';
import '../storage/markdown_refs.dart';
import 'markdown_view.dart';

/// 块级"所见即所得"编辑器（Typora 式近似）。
///
/// 整篇按块渲染（图片就地显示、`#`/`**` 等标记隐藏）；点某一块才把它变回
/// 可编辑的 Markdown 源码，失焦即提交并重新渲染。源数据始终是 [body] 这份
/// 完整 Markdown：组件内部维护一份块列表，提交时用 `\n\n` 拼回写入 [body]。
///
/// 已知 v1 局限：编辑中把某块清空（删除该块）后立刻点更靠后的块，可能因下标
/// 偏移落到相邻块——再点一次即可。复杂表格/批量编辑建议切「整篇源码」(⌘/Ctrl+P)。
class BlockEditor extends StatefulWidget {
  const BlockEditor({
    super.key,
    required this.body,
    required this.attachments,
    required this.onCommit,
  });

  /// 完整 Markdown 正文（唯一数据源）。
  final TextEditingController body;
  final AttachmentStore attachments;

  /// 提交任何改动后回调，父级据此保存 / 触发同步。
  final VoidCallback onCommit;

  @override
  State<BlockEditor> createState() => BlockEditorState();
}

class BlockEditorState extends State<BlockEditor> {
  late List<String> _blocks;
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  int? _editing; // 正在编辑的块下标（null=无）

  @override
  void initState() {
    super.initState();
    _blocks = splitBlocks(widget.body.text);
    _focus.addListener(() {
      if (!_focus.hasFocus) commitPending();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _writeBack() {
    widget.body.text = _blocks.join('\n\n');
    widget.onCommit();
  }

  void _startEdit(int index) {
    if (_editing == index) return;
    commitPending(); // 先提交上一处
    setState(() {
      _editing = index;
      _ctl.text = index < _blocks.length ? _blocks[index] : '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
    });
  }

  /// 提交当前正在编辑的块（若有）。供失焦、退出页面、切「整篇源码」前调用。
  void commitPending() {
    final i = _editing;
    if (i == null) return;
    _editing = null;
    final text = _ctl.text.trim();
    var changed = false;
    if (i < _blocks.length) {
      if (text.isEmpty) {
        _blocks.removeAt(i); // 清空即删除该块
        changed = true;
      } else if (_blocks[i] != text) {
        _blocks[i] = text;
        changed = true;
      }
    } else if (text.isNotEmpty) {
      _blocks.add(text); // 新建的尾块
      changed = true;
    }
    if (mounted) setState(() {});
    if (changed) _writeBack();
  }

  void _addBlock() => _startEdit(_blocks.length);

  /// 在末尾追加一张图片块（供父级"插入图片"按钮调用）。
  void insertImageRef(String ref) {
    commitPending();
    setState(() => _blocks.add('![]($ref)'));
    _writeBack();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[];
    for (var i = 0; i < _blocks.length; i++) {
      children.add(i == _editing
          ? _editingField(theme)
          : _renderedBlock(theme, _blocks[i], i));
    }
    // 编辑新建的尾块时，下标会等于 _blocks.length。
    if (_editing != null && _editing! >= _blocks.length) {
      children.add(_editingField(theme));
    }
    children.add(_addTarget(theme));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: children,
    );
  }

  Widget _editingField(ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: TextField(
          controller: _ctl,
          focusNode: _focus,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: theme.textTheme.bodyLarge,
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: '写点什么…（Markdown）',
          ),
        ),
      );

  Widget _renderedBlock(ThemeData theme, String block, int index) => InkWell(
        onTap: () => _startEdit(index),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 2),
          // selectable:false → 点击落到"编辑"而非起选区。
          child: MarkdownView(
            data: block,
            attachments: widget.attachments,
            selectable: false,
          ),
        ),
      );

  Widget _addTarget(ThemeData theme) => InkWell(
        onTap: _addBlock,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '＋ 继续写…',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      );
}
