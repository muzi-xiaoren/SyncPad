import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'attachment_store.dart';
import 'markdown_refs.dart';
import 'note_repository.dart';

/// 导入一个本地 Markdown 文件的结果。
class ImportResult {
  final String noteId;
  final String title;
  final int imagesFound; // 正文里引用的本地/内嵌图片数
  final int imagesIngested; // 成功拉进附件仓的数量
  final int imagesMissing; // 找不到/读取失败的数量
  const ImportResult({
    required this.noteId,
    required this.title,
    required this.imagesFound,
    required this.imagesIngested,
    required this.imagesMissing,
  });
}

/// 导入一个本地 `.md` 文件：扫描其中引用的**本地图片 / data: 内嵌图**，
/// 拉进 [attachments]（内容寻址 + 降采样），把引用改写成 `attachments/<name>`，
/// 然后以文件名为标题新建一条笔记。网络图 `http(s)://` 原样保留。
///
/// 相对图片路径相对 [filePath] 所在目录解析；[bytes] 为空时从 [filePath] 读取。
Future<ImportResult> importMarkdown({
  required NoteRepository repo,
  required AttachmentStore attachments,
  required String fileName,
  String? filePath,
  Uint8List? bytes,
}) async {
  final raw = bytes != null
      ? utf8.decode(bytes, allowMalformed: true)
      : await File(filePath!).readAsString();
  final baseDir = filePath != null ? File(filePath).parent.path : null;

  final replace = <String, String>{};
  var found = 0, ingested = 0, missing = 0;

  for (final url in imageUrlsIn(raw)) {
    if (url.startsWith('http://') || url.startsWith('https://')) continue;
    if (url.startsWith(attachmentRefPrefix)) continue; // 已是本仓库附件

    found++;
    try {
      final (imgBytes, ext) = await _readImage(url, baseDir);
      if (imgBytes == null) {
        missing++;
        continue;
      }
      replace[url] = await attachments.add(imgBytes, sourceExt: ext);
      ingested++;
    } catch (_) {
      missing++;
    }
  }

  final body = rewriteImageUrls(raw, replace);
  final title = _titleFromFileName(fileName);
  final id = await repo.addNote(title: title, body: body);

  return ImportResult(
    noteId: id,
    title: title,
    imagesFound: found,
    imagesIngested: ingested,
    imagesMissing: missing,
  );
}

/// 读取一个图片引用的字节 + 扩展名提示。找不到返回 (null, null)。
Future<(Uint8List?, String?)> _readImage(String url, String? baseDir) async {
  // data:image/...;base64,xxxx 内嵌图
  if (url.startsWith('data:')) {
    final data = Uri.parse(url).data;
    if (data == null) return (null, null);
    final mime = data.mimeType; // image/png 等
    final ext = mime.contains('/') ? mime.split('/').last : null;
    return (Uint8List.fromList(data.contentAsBytes()), ext);
  }

  final path = _toLocalPath(url, baseDir);
  if (path == null) return (null, null);
  final f = File(path);
  if (!await f.exists()) return (null, null);
  return (await f.readAsBytes(), p.extension(path));
}

/// 把图片 URL 解析成本地绝对路径；无法解析（如未带 baseDir 的相对路径）返回 null。
String? _toLocalPath(String url, String? baseDir) {
  var u = url;
  if (u.startsWith('file://')) {
    return Uri.parse(u).toFilePath();
  }
  // URL 编码（空格等）解码；非法编码就用原串。
  try {
    u = Uri.decodeFull(u);
  } catch (_) {}
  if (p.isAbsolute(u)) return u;
  if (baseDir == null) return null;
  return p.normalize(p.join(baseDir, u));
}

String _titleFromFileName(String fileName) {
  final base = p.basenameWithoutExtension(fileName).trim();
  return base.isEmpty ? '导入的笔记' : base;
}
