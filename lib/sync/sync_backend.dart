import 'dart:typed_data';

/// 抽象远端后端。GitHub / Gitee / WebDAV 都按单个日志文件同步。
abstract class SyncBackend {
  /// 拉取远端当前文件 + commit/version 标识。文件不存在时 [content] 为空字节、[version] 为 null。
  Future<RemoteSnapshot> pull();

  /// 上传新内容；需要带上"基线 version"，远端若不一致返回冲突（[PushOutcome.conflict]）。
  ///
  /// [force] = true 时**无条件覆盖**远端（忽略基线校验）。用于副仓库冲突兜底：
  /// 先 pull+merge 保证不丢数据，再强制写入，避免坚果云 ETag 漂移导致反复假冲突。
  Future<PushOutcome> push({
    required Uint8List content,
    required String? baseVersion,
    required String commitMessage,
    bool force = false,
  });

  /// 仅检查远端最新 version，用于"智能跳过"。失败抛异常。
  Future<String?> headVersion();

  /// 测试连接：验证服务器可达 + 鉴权通过 + 仓库/路径有效。
  /// 与 [headVersion] 的区别：它会把"仓库/项目不存在"当作**失败**抛出。
  /// 成功返回远端当前 version（无文件时为 null）。
  Future<String?> testConnection();

  /// 后端类型名（github / gitee / webdav），用于状态展示。
  String get name;

  // ---- 图片附件同步（操作与 notes 文件同目录下的 attachments/ 子目录）----
  // 附件内容寻址（文件名=sha1），同名必同字节，因此无需冲突合并：只“补齐缺失”。

  /// 列出远端 attachments/ 下已存在的文件名；目录不存在返回空集。
  Future<Set<String>> listAttachments();

  /// 下载单个附件字节；不存在返回 null。
  Future<Uint8List?> getAttachment(String name);

  /// 上传单个附件（仅在远端缺失时调用）。
  Future<void> putAttachment(String name, Uint8List bytes);
}

class RemoteSnapshot {
  final Uint8List content;
  final String? version;
  final bool exists;

  const RemoteSnapshot({
    required this.content,
    required this.version,
    required this.exists,
  });
}

enum PushOutcome { ok, conflict }

/// 语义化错误类型，便于 UI 层映射到提示文案。
enum SyncErrorKind {
  /// 普通 HTTP 错误，直接展示 statusCode + 服务器返回的 message。
  http,

  /// 仓库不存在 / 令牌无权访问（Owner、Repo 填错时）。
  repoNotFound,

  /// WebDAV 目标文件夹不存在（坚果云需先手动建文件夹）。
  webdavFolderMissing,
}

class SyncException implements Exception {
  final String message;
  final int? statusCode;
  final SyncErrorKind kind;
  const SyncException(
    this.message, {
    this.statusCode,
    this.kind = SyncErrorKind.http,
  });
  @override
  String toString() => 'SyncException($statusCode): $message';
}
