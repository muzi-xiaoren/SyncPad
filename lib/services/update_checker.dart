import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一次更新检查的结果。
class UpdateInfo {
  /// 远端最新版本号（已去掉前缀 v，如 "0.0.2"）。
  final String latestVersion;

  /// Release 页面地址，供“前往下载”跳转。
  final String htmlUrl;

  /// 远端是否比当前版本更新。
  final bool hasUpdate;

  const UpdateInfo({
    required this.latestVersion,
    required this.htmlUrl,
    required this.hasUpdate,
  });
}

/// 检查是否有新版本。
///
/// 故意不走 `api.github.com`：未带 token 的 GitHub API 每个 IP 每小时仅
/// 60 次，手机走运营商 CGNAT 时同一公网 IP 被大量用户共享，极易被陌生人
/// 耗光额度导致 403（即“检查更新失败”）。客户端又不能内嵌 token。
///
/// 改用 github.com 的网页端点（不受那条 60 次/小时的 API 限流约束）：
///   1. `releases/latest` —— 302 跳转到 `releases/tag/<tag>`，读 Location 头；
///   2. 兜底用 `releases.atom` 订阅源，第一条即最新 release。
class UpdateChecker {
  static const String _repo = 'https://github.com/muzi-xiaoren/SyncPad';
  static const String _ua = 'SyncPad-app';
  static const String releasesPage = '$_repo/releases/latest';

  /// 查询最新 Release 并与 [currentVersion]（如 "0.0.1"）比较。
  /// 网络失败会抛异常，由调用方处理。
  static Future<UpdateInfo> check(String currentVersion) async {
    final found = await _tryRedirect() ?? await _tryAtom();
    if (found == null) {
      throw Exception('no release found');
    }
    final latest = _stripV(found.tag);
    return UpdateInfo(
      latestVersion: latest.isEmpty ? currentVersion : latest,
      htmlUrl: found.url,
      hasUpdate: latest.isNotEmpty && _isNewer(latest, currentVersion),
    );
  }

  /// 请求 `releases/latest` 但不跟随重定向，从 302 的 Location 头解析 tag。
  static Future<({String tag, String url})?> _tryRedirect() async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse('$_repo/releases/latest'))
        ..followRedirects = false
        ..headers['User-Agent'] = _ua;
      final resp = await client.send(req).timeout(const Duration(seconds: 12));
      await resp.stream.drain<void>();
      final loc = resp.headers['location'];
      final tag = _tagFromUrl(loc);
      if (tag != null && loc != null) return (tag: tag, url: loc);
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 兜底：解析 atom 订阅源里第一条 release 的 tag 链接。
  static Future<({String tag, String url})?> _tryAtom() async {
    try {
      final resp = await http.get(
        Uri.parse('$_repo/releases.atom'),
        headers: const {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final body = utf8.decode(resp.bodyBytes);
      final m = RegExp(r'/releases/tag/([^"/?#<\s]+)').firstMatch(body);
      final tag = m?.group(1);
      if (tag == null || tag.isEmpty) return null;
      return (tag: tag, url: '$_repo/releases/tag/$tag');
    } catch (_) {
      return null;
    }
  }

  /// 从形如 `.../releases/tag/v0.0.2` 的地址里取出 tag。
  static String? _tagFromUrl(String? url) {
    if (url == null) return null;
    final m = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(url);
    return m?.group(1);
  }

  static String _stripV(String tag) {
    var t = tag.trim();
    if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
    return t;
  }

  /// a 是否比 b 新（按点分数字逐段比较，忽略非数字后缀）。
  static bool isNewer(String a, String b) => _isNewer(a, b);

  static bool _isNewer(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static List<int> _parts(String v) {
    if (v.isEmpty) return const [0];
    return v.split('.').map((s) {
      final m = RegExp(r'\d+').firstMatch(s);
      return m == null ? 0 : int.parse(m.group(0)!);
    }).toList();
  }
}
