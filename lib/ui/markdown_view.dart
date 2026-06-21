import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../storage/attachment_store.dart';
import '../storage/markdown_refs.dart';

/// 渲染 Markdown 正文。图片按来源分流：
/// - `attachments/<name>`：从本地附件仓加载（没有则显示“未同步”占位）
/// - `http(s)://`：网络图
/// - `data:`：内嵌 base64 图
class MarkdownView extends StatelessWidget {
  const MarkdownView({
    super.key,
    required this.data,
    required this.attachments,
    this.selectable = true,
  });

  final String data;
  final AttachmentStore attachments;

  /// 是否可选中文本。块级编辑器里设 false，让点击落到"点我编辑"上而非起选区。
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: expandToc(data),
      selectable: selectable,
      imageBuilder: (uri, title, alt) => _Img(
        uri: uri,
        alt: alt,
        attachments: attachments,
      ),
    );
  }
}

class _Img extends StatelessWidget {
  const _Img({required this.uri, required this.alt, required this.attachments});

  final Uri uri;
  final String? alt;
  final AttachmentStore attachments;

  @override
  Widget build(BuildContext context) {
    final s = uri.toString();
    Widget img;
    if (s.startsWith('data:')) {
      final bytes = uri.data?.contentAsBytes();
      img = bytes == null
          ? _placeholder(context, Icons.broken_image_outlined, alt ?? '图片')
          : Image.memory(bytes, errorBuilder: _err(context));
    } else if (uri.scheme == 'http' || uri.scheme == 'https') {
      img = Image.network(s, errorBuilder: _err(context));
    } else {
      final name = attachmentNameOf(s) ?? s.split('/').last;
      final f = attachments.fileForRef(name);
      img = f.existsSync()
          ? Image.file(f, errorBuilder: _err(context))
          : _placeholder(context, Icons.cloud_off_outlined, '图片未同步');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(borderRadius: BorderRadius.circular(10), child: img),
    );
  }

  ImageErrorWidgetBuilder _err(BuildContext context) =>
      (_, _, _) => _placeholder(context, Icons.broken_image_outlined, alt ?? '图片');

  Widget _placeholder(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 8),
          Flexible(child: Text(label, style: TextStyle(color: scheme.outline))),
        ],
      ),
    );
  }
}
