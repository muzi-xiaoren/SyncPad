import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../settings/app_settings.dart';
import 'sync_backend.dart';

/// WebDAV 后端，用于坚果云 / Nextcloud / NAS 等云端文件夹。
///
/// 字段复用 [BackendConfig]：
/// - owner: WebDAV 用户名（坚果云填账号邮箱）
/// - repo: WebDAV 服务器地址，如 https://dav.jianguoyun.com/dav/
/// - filePath: 远程文件路径，如 /SyncPad/notes.log
class WebDavBackend implements SyncBackend {
  WebDavBackend({
    required this.config,
    required String password,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 10),
  })  : _password = password,
        _http = httpClient ?? http.Client(),
        _timeout = timeout;

  final BackendConfig config;

  final String _password;
  final http.Client _http;
  final Duration _timeout;

  @override
  String get name => 'webdav';

  Map<String, String> get _headers => {
        'Authorization':
            'Basic ${base64.encode(utf8.encode('${config.owner}:$_password'))}',
        'User-Agent': 'SyncPad',
      };

  Uri _fileUri() {
    final base = config.repo.endsWith('/') ? config.repo : '${config.repo}/';
    final path = config.filePath.startsWith('/')
        ? config.filePath.substring(1)
        : config.filePath;
    return Uri.parse(base).resolve(path);
  }

  String? _versionFrom(http.Response resp) =>
      resp.headers['etag'] ?? resp.headers['last-modified'];

  @override
  Future<RemoteSnapshot> pull() async {
    final resp =
        await _http.get(_fileUri(), headers: _headers).timeout(_timeout);
    // 坚果云在"父文件夹尚不存在"时返回 409 而非 404；读取场景下都按"远端无文件"处理。
    if (resp.statusCode == 404 || resp.statusCode == 409) {
      return RemoteSnapshot(content: Uint8List(0), version: null, exists: false);
    }
    if (resp.statusCode >= 400) {
      throw SyncException(resp.body, statusCode: resp.statusCode);
    }
    return RemoteSnapshot(
      content: resp.bodyBytes,
      version: _versionFrom(resp),
      exists: true,
    );
  }

  @override
  Future<String?> headVersion() async {
    final req = http.Request('HEAD', _fileUri())..headers.addAll(_headers);
    final streamed = await _http.send(req).timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode == 404 || resp.statusCode == 409) return null;
    if (resp.statusCode >= 400) {
      throw SyncException(resp.body, statusCode: resp.statusCode);
    }
    return _versionFrom(resp);
  }

  @override
  Future<String?> testConnection() async {
    final req = http.Request('HEAD', _fileUri())..headers.addAll(_headers);
    final streamed = await _http.send(req).timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    // 文件夹已存在、文件还没建 → 正常（首次 push 会创建文件）。
    if (resp.statusCode == 404) return null;
    // 坚果云：父文件夹不存在时返回 409，且不能通过 WebDAV 自动建顶层文件夹，
    // 必须先在坚果云里手动建好 —— 明确提示用户。
    if (resp.statusCode == 409) {
      throw SyncException(
        'target folder does not exist',
        statusCode: 409,
        kind: SyncErrorKind.webdavFolderMissing,
      );
    }
    if (resp.statusCode >= 400) {
      throw SyncException(resp.body, statusCode: resp.statusCode);
    }
    return _versionFrom(resp);
  }

  @override
  Future<PushOutcome> push({
    required Uint8List content,
    required String? baseVersion,
    required String commitMessage,
    bool force = false,
  }) async {
    await _ensureDirectories();
    // force（副仓库冲突兜底）：不带条件头直接覆盖。坚果云 ETag 不稳定，
    // 条件请求会反复 412 假冲突，强制写入才能可靠收敛。
    if (force) {
      final resp = await _http
          .put(_fileUri(), headers: {
            ..._headers,
            'Content-Type': 'application/octet-stream',
          }, body: content)
          .timeout(_timeout);
      if (resp.statusCode >= 400) {
        throw SyncException(resp.body, statusCode: resp.statusCode);
      }
      return PushOutcome.ok;
    }
    final headers = {
      ..._headers,
      'Content-Type': 'application/octet-stream',
      'If-Match': ?baseVersion,
      if (baseVersion == null) 'If-None-Match': '*',
    };
    var resp = await _http
        .put(_fileUri(), headers: headers, body: content)
        .timeout(_timeout);
    if (resp.statusCode == 412 || resp.statusCode == 409) {
      if (baseVersion == null) {
        resp = await _http
            .put(_fileUri(), headers: {
              ..._headers,
              'Content-Type': 'application/octet-stream',
            }, body: content)
            .timeout(_timeout);
      } else {
        // 坚果云 ETag/If-Match 并不总是稳定：内容其实没变时也可能回 412。
        // 拉一次远端内容比对——完全相同就当作"已是最新"，否则才是真冲突。
        final current = await pull();
        if (current.exists && _bytesEqual(current.content, content)) {
          return PushOutcome.ok;
        }
        return PushOutcome.conflict;
      }
    }
    if (resp.statusCode >= 400) {
      throw SyncException(resp.body, statusCode: resp.statusCode);
    }
    return PushOutcome.ok;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _ensureDirectories() async {
    final parts = config.filePath
        .split('/')
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) return;

    final base = config.repo.endsWith('/') ? config.repo : '${config.repo}/';
    var current = Uri.parse(base);
    for (final part in parts.take(parts.length - 1)) {
      current = current.resolve('$part/');
      final req = http.Request('MKCOL', current)..headers.addAll(_headers);
      final streamed = await _http.send(req).timeout(_timeout);
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 201 ||
          resp.statusCode == 405 ||
          resp.statusCode == 301 ||
          resp.statusCode == 302) {
        continue;
      }
      if (resp.statusCode >= 400) {
        throw SyncException(resp.body, statusCode: resp.statusCode);
      }
    }
  }

  // ---- 附件 ----

  /// notes 文件同目录下的 attachments/ 子目录段（如 ['SyncPad','attachments']）。
  List<String> get _attDirSegments {
    final fp = config.filePath.startsWith('/')
        ? config.filePath.substring(1)
        : config.filePath;
    final slash = fp.lastIndexOf('/');
    final dir = slash < 0 ? '' : fp.substring(0, slash + 1);
    return '${dir}attachments'.split('/').where((s) => s.isNotEmpty).toList();
  }

  Uri _attUri(String name) {
    final base = config.repo.endsWith('/') ? config.repo : '${config.repo}/';
    return Uri.parse(base).resolve('${_attDirSegments.join('/')}/$name');
  }

  @override
  Future<Set<String>> listAttachments() async {
    final dirUri = _attUri(''); // 末尾带 / 的集合地址
    final req = http.Request('PROPFIND', dirUri)
      ..headers.addAll({..._headers, 'Depth': '1', 'Content-Type': 'application/xml'})
      ..body =
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';
    final streamed = await _http.send(req).timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode == 404 || resp.statusCode == 409) return {};
    if (resp.statusCode >= 400) {
      throw SyncException(resp.body, statusCode: resp.statusCode);
    }
    final out = <String>{};
    final hrefRe = RegExp(r'<[a-zA-Z]*:?href>([^<]+)</[a-zA-Z]*:?href>');
    for (final m in hrefRe.allMatches(resp.body)) {
      var href = m.group(1)!.trim();
      if (href.endsWith('/')) continue; // 集合本身或子目录
      try {
        href = Uri.decodeFull(href);
      } catch (_) {}
      final name = href.split('/').last;
      if (name.isNotEmpty) out.add(name);
    }
    return out;
  }

  @override
  Future<Uint8List?> getAttachment(String name) async {
    final resp =
        await _http.get(_attUri(name), headers: _headers).timeout(_timeout);
    if (resp.statusCode == 404 || resp.statusCode == 409) return null;
    if (resp.statusCode >= 400) {
      throw SyncException(resp.body, statusCode: resp.statusCode);
    }
    return resp.bodyBytes;
  }

  @override
  Future<void> putAttachment(String name, Uint8List bytes) async {
    await _ensureAttachmentsDir();
    final resp = await _http
        .put(_attUri(name),
            headers: {..._headers, 'Content-Type': 'application/octet-stream'},
            body: bytes)
        .timeout(_timeout);
    if (resp.statusCode >= 400) {
      throw SyncException(resp.body, statusCode: resp.statusCode);
    }
  }

  Future<void> _ensureAttachmentsDir() async {
    final base = config.repo.endsWith('/') ? config.repo : '${config.repo}/';
    var current = Uri.parse(base);
    for (final seg in _attDirSegments) {
      current = current.resolve('$seg/');
      final req = http.Request('MKCOL', current)..headers.addAll(_headers);
      final streamed = await _http.send(req).timeout(_timeout);
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 201 ||
          resp.statusCode == 405 ||
          resp.statusCode == 301 ||
          resp.statusCode == 302) {
        continue;
      }
      if (resp.statusCode >= 400) {
        throw SyncException(resp.body, statusCode: resp.statusCode);
      }
    }
  }
}
