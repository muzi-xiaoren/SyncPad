import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'markdown_refs.dart';

/// 图片附件的本地仓库：**内容寻址**——文件名 = 内容 sha1 + 扩展名。
/// 物理目录：`<app_support>/SyncPad/attachments/`。
///
/// 正文里以 `![](attachments/<sha1>.<ext>)` 引用。同名必同字节，所以跨端
/// 同步只需“补齐缺失文件”，不需要任何冲突合并（见 SyncManager 的附件同步）。
class AttachmentStore {
  AttachmentStore(this.dir);

  /// attachments 目录（构造时已确保存在）。
  final Directory dir;

  static const maxEdge = 2560; // 降采样长边上限
  static const jpegQuality = 88;
  static const keepOriginalMaxBytes = 1024 * 1024; // 未超尺寸且 <1MB 的图保留原文件

  static Future<AttachmentStore> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'SyncPad', 'attachments'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return AttachmentStore(dir);
  }

  /// 处理并存入一张图片，返回 Markdown 引用 `attachments/<name>`。
  /// 已存在（同内容）则跳过写入。
  Future<String> add(Uint8List bytes, {String? sourceExt}) async {
    final prepared = prepareImage(bytes, sourceExt: sourceExt);
    final name = '${sha1.convert(prepared.bytes)}.${prepared.ext}';
    final f = File(p.join(dir.path, name));
    if (!await f.exists()) await f.writeAsBytes(prepared.bytes, flush: true);
    return '$attachmentRefPrefix$name';
  }

  /// 同步拉取用：按裸文件名写入（字节已是最终内容，不再处理）。
  Future<void> writeNamed(String name, Uint8List bytes) async {
    final f = File(p.join(dir.path, _basename(name)));
    if (!await f.exists()) await f.writeAsBytes(bytes, flush: true);
  }

  File fileForRef(String refOrName) => File(p.join(dir.path, _basename(refOrName)));
  Future<bool> hasName(String name) => fileForRef(name).exists();

  Future<Uint8List?> bytesForName(String name) async {
    final f = fileForRef(name);
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// 本地已有的附件文件名集合。
  Future<Set<String>> localNames() async {
    if (!await dir.exists()) return {};
    final out = <String>{};
    await for (final e in dir.list()) {
      if (e is File) out.add(p.basename(e.path));
    }
    return out;
  }

  static String _basename(String refOrName) {
    final s = refOrName.startsWith(attachmentRefPrefix)
        ? refOrName.substring(attachmentRefPrefix.length)
        : refOrName;
    return s.split('/').last.split('?').first.split('#').first;
  }
}

/// 处理结果：最终要落盘的字节 + 扩展名（不含点）。
class PreparedImage {
  final Uint8List bytes;
  final String ext;
  const PreparedImage(this.bytes, this.ext);
}

/// 纯函数：解码 → 必要时降采样到长边 [maxEdge] 并重编码 JPEG(q[quality])。
///
/// - 解码失败（未知格式）：原样返回，扩展名取 [sourceExt] 或嗅探或 `img`。
/// - 未超尺寸且 < [keepOriginalMaxBytes]：保留原始字节与原扩展名（保住 PNG 透明等）。
/// - 否则：等比缩到长边 [maxEdge]，编码 JPEG。
PreparedImage prepareImage(
  Uint8List bytes, {
  String? sourceExt,
  int maxEdge = AttachmentStore.maxEdge,
  int quality = AttachmentStore.jpegQuality,
  int keepOriginalMaxBytes = AttachmentStore.keepOriginalMaxBytes,
}) {
  final ext0 = normalizeImageExt(sourceExt) ?? sniffImageExt(bytes);
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return PreparedImage(bytes, ext0 ?? 'img');
  }
  final longEdge =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longEdge <= maxEdge && bytes.length <= keepOriginalMaxBytes) {
    return PreparedImage(bytes, ext0 ?? 'png');
  }
  final resized = longEdge <= maxEdge
      ? decoded
      : (decoded.width >= decoded.height
          ? img.copyResize(decoded,
              width: maxEdge, interpolation: img.Interpolation.average)
          : img.copyResize(decoded,
              height: maxEdge, interpolation: img.Interpolation.average));
  final jpg = img.encodeJpg(resized, quality: quality);
  return PreparedImage(Uint8List.fromList(jpg), 'jpg');
}

/// 归一化扩展名：去点、小写、jpeg→jpg；不在已知图片集合里返回 null。
String? normalizeImageExt(String? ext) {
  if (ext == null) return null;
  var e = ext.toLowerCase();
  if (e.startsWith('.')) e = e.substring(1);
  if (e == 'jpeg') e = 'jpg';
  const known = {'jpg', 'png', 'gif', 'webp', 'bmp'};
  return known.contains(e) ? e : null;
}

/// 按 magic bytes 嗅探图片扩展名，认不出返回 null。
String? sniffImageExt(Uint8List b) {
  if (b.length >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'jpg';
  if (b.length >= 4 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
    return 'gif';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return 'webp';
  }
  if (b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
  return null;
}
