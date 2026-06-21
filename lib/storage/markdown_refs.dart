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

// 独占一行的 `[TOC]` / `[toc]` 标记（忽略大小写、首尾空白，允许 \r 行尾）。
final _tocRe =
    RegExp(r'^[ \t]*\[toc\][ \t]*\r?$', multiLine: true, caseSensitive: false);
// ATX 标题：1~6 个 # + 空格 + 文本（去掉行尾可能的收尾 #）。
final _headingRe = RegExp(r'^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$');
// 围栏代码块起止：``` 或 ~~~。
final _fenceRe = RegExp(r'^[ \t]*(`{3,}|~{3,})');

/// 把 Markdown 里独占一行的 `[TOC]` 标记展开成基于标题的目录（缩进无序列表）。
///
/// 很多编辑器（Typora 等）支持 `[TOC]` 自动目录，但标准 Markdown 渲染器不认识，
/// 会原样显示出 “[TOC]” 这几个字。这里在渲染前把它替换成文档各级标题组成的
/// 嵌套列表；代码块内的 `#` 不计为标题。没有标题时直接抹掉该标记。
String expandToc(String markdown) {
  if (!_tocRe.hasMatch(markdown)) return markdown;

  final headings = <({int level, String text})>[];
  var inFence = false;
  for (final raw in markdown.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (_fenceRe.hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final m = _headingRe.firstMatch(line);
    if (m != null) {
      headings.add((level: m.group(1)!.length, text: m.group(2)!.trim()));
    }
  }

  if (headings.isEmpty) return markdown.replaceAll(_tocRe, '');

  final minLevel =
      headings.map((h) => h.level).reduce((a, b) => a < b ? a : b);
  final sb = StringBuffer();
  for (final h in headings) {
    final indent = '    ' * (h.level - minLevel); // 每级 4 空格 → 嵌套列表生效
    sb.writeln('$indent- ${h.text}');
  }
  // 前后各留一空行，避免目录列表和相邻段落黏在一起。
  return markdown.replaceAll(_tocRe, '\n${sb.toString().trimRight()}\n');
}

/// 把 Markdown 拆成"块"：以空行分隔的连续非空行各为一块；围栏代码块
/// (``` / ~~~) 内部的空行不作为分隔。块级编辑器用它把整篇切成可单独编辑的单元。
/// 反向用 `blocks.join('\n\n')` 还原（多余空行会被归一为一行）。
List<String> splitBlocks(String text) {
  final blocks = <String>[];
  final cur = <String>[];
  var inFence = false;
  String? fenceChar;

  void flush() {
    while (cur.isNotEmpty && cur.last.trim().isEmpty) {
      cur.removeLast();
    }
    if (cur.isNotEmpty) {
      blocks.add(cur.join('\n'));
      cur.clear();
    }
  }

  for (final raw in text.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final fm = _fenceRe.firstMatch(line);
    if (fm != null) {
      final ch = fm.group(1)![0]; // ` 或 ~
      if (!inFence) {
        inFence = true;
        fenceChar = ch;
      } else if (fenceChar == ch) {
        inFence = false;
        fenceChar = null;
      }
      cur.add(line);
      continue;
    }
    if (!inFence && line.trim().isEmpty) {
      flush();
    } else {
      cur.add(line);
    }
  }
  flush();
  return blocks;
}
