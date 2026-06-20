/// Markdown 图片引用的解析 / 改写工具（纯函数，无 IO、无第三方依赖）。
///
/// 笔记正文里图片统一用标准 Markdown 语法 `![alt](url)`。本仓库的附件引用形如
/// `![](attachments/<sha1>.<ext>)`，`attachments/` 前缀是约定的“本地附件”标记。
library;

/// 本地附件引用前缀。
const attachmentRefPrefix = 'attachments/';

// ![alt](url "可选标题")：alt 不含 ]，url 取到第一个空白或 ) 为止。
final _imgRe = RegExp(r'!\[[^\]]*\]\(\s*(<[^>]+>|[^)\s]+)[^)]*\)');

/// 去掉 url 外层可能存在的尖括号。
String _unwrap(String url) =>
    (url.startsWith('<') && url.endsWith('>'))
        ? url.substring(1, url.length - 1)
        : url;

/// 提取正文里所有图片 URL（去重、保持出现顺序）。
List<String> imageUrlsIn(String text) {
  final out = <String>[];
  for (final m in _imgRe.allMatches(text)) {
    final u = _unwrap(m.group(1) ?? '');
    if (u.isNotEmpty && !out.contains(u)) out.add(u);
  }
  return out;
}

/// 其中指向本仓库附件（`attachments/...`）的文件名集合（去掉前缀、查询串）。
Set<String> attachmentNamesIn(String text) {
  final out = <String>{};
  for (final u in imageUrlsIn(text)) {
    final name = attachmentNameOf(u);
    if (name != null) out.add(name);
  }
  return out;
}

/// 若 [url] 是本仓库附件引用，返回其裸文件名，否则 null。
String? attachmentNameOf(String url) {
  if (!url.startsWith(attachmentRefPrefix)) return null;
  final rest = url.substring(attachmentRefPrefix.length);
  return rest.split('/').last.split('?').first.split('#').first;
}

/// 按映射 [replace]（旧 url → 新 url）改写正文里的图片引用，其余原样保留。
String rewriteImageUrls(String text, Map<String, String> replace) {
  if (replace.isEmpty) return text;
  return text.replaceAllMapped(_imgRe, (m) {
    final whole = m.group(0)!;
    final url = _unwrap(m.group(1) ?? '');
    final repl = replace[url];
    if (repl == null) return whole;
    // 只替换匹配段内的 url 部分，保留 alt / 标题。
    return whole.replaceFirst(m.group(1)!, repl);
  });
}

/// 用于列表卡片预览：把图片引用替换成占位符 [图片]，避免卡片里露出一长串路径。
String stripImagesForPreview(String text) =>
    text.replaceAll(_imgRe, '[图片]');
