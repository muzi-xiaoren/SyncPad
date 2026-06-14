import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BackendKind { github, gitee, webdav }

enum BackendRole { primary, mirror }

class BackendConfig {
  final BackendKind kind;
  final bool enabled;
  final BackendRole role;
  final String owner;
  final String repo;
  final String branch;
  final String filePath;

  const BackendConfig({
    required this.kind,
    this.enabled = false,
    this.role = BackendRole.primary,
    this.owner = '',
    this.repo = '',
    this.branch = 'main',
    this.filePath = 'notes.log',
  });

  BackendConfig copyWith({
    bool? enabled,
    BackendRole? role,
    String? owner,
    String? repo,
    String? branch,
    String? filePath,
  }) {
    return BackendConfig(
      kind: kind,
      enabled: enabled ?? this.enabled,
      role: role ?? this.role,
      owner: owner ?? this.owner,
      repo: repo ?? this.repo,
      branch: branch ?? this.branch,
      filePath: filePath ?? this.filePath,
    );
  }

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'enabled': enabled,
        'role': role.name,
        'owner': owner,
        'repo': repo,
        'branch': branch,
        'filePath': filePath,
      };

  static BackendConfig fromJson(Map<String, Object?> j) {
    final kind = BackendKind.values.firstWhere((e) => e.name == j['kind']);
    return BackendConfig(
      kind: kind,
      enabled: j['enabled'] as bool? ?? false,
      role: BackendRole.values
          .firstWhere((e) => e.name == (j['role'] ?? 'primary')),
      owner: j['owner'] as String? ?? '',
      repo: j['repo'] as String? ?? '',
      branch: j['branch'] as String? ?? defaultBranchFor(kind),
      filePath: j['filePath'] as String? ?? defaultFilePathFor(kind),
    );
  }

  static String defaultBranchFor(BackendKind kind) => switch (kind) {
        BackendKind.gitee => 'master',
        BackendKind.webdav => '',
        BackendKind.github => 'main',
      };

  static String defaultFilePathFor(BackendKind kind) =>
      kind == BackendKind.webdav ? '/SyncPad/notes.log' : 'notes.log';

  static String defaultRepoFor(BackendKind kind) =>
      kind == BackendKind.webdav ? 'https://dav.jianguoyun.com/dav/' : '';
}

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const _kCloudEnabled = 'cloud_enabled';
  static const _kAutoSyncOnLaunch = 'auto_sync_on_launch';
  static const _kPushAfterEdit = 'push_after_edit';
  static const _kBackendGithub = 'backend_github_json';
  static const _kBackendGitee = 'backend_gitee_json';
  static const _kBackendWebDav = 'backend_webdav_json';

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings._(prefs);
  }

  bool get cloudEnabled => _prefs.getBool(_kCloudEnabled) ?? false;

  /// 启动时自动从远端拉取并合并。默认开。
  bool get autoSyncOnLaunch => _prefs.getBool(_kAutoSyncOnLaunch) ?? true;

  /// 新增/编辑/删除后自动推送到远端。默认开。
  bool get pushAfterEdit => _prefs.getBool(_kPushAfterEdit) ?? true;

  BackendConfig get github => _loadBackend(_kBackendGithub, BackendKind.github);
  BackendConfig get gitee => _loadBackend(_kBackendGitee, BackendKind.gitee);
  BackendConfig get webdav => _loadBackend(_kBackendWebDav, BackendKind.webdav);

  BackendConfig _loadBackend(String key, BackendKind kind) {
    final raw = _prefs.getString(key);
    if (raw == null) {
      return BackendConfig(
        kind: kind,
        role:
            kind == BackendKind.github ? BackendRole.primary : BackendRole.mirror,
        branch: BackendConfig.defaultBranchFor(kind),
        repo: BackendConfig.defaultRepoFor(kind),
        filePath: BackendConfig.defaultFilePathFor(kind),
      );
    }
    try {
      return BackendConfig.fromJson(_decode(raw));
    } catch (_) {
      return BackendConfig(
        kind: kind,
        branch: BackendConfig.defaultBranchFor(kind),
        repo: BackendConfig.defaultRepoFor(kind),
        filePath: BackendConfig.defaultFilePathFor(kind),
      );
    }
  }

  /// 返回当前 primary 后端（若启用），否则 null。
  BackendConfig? get primaryBackend {
    if (!cloudEnabled) return null;
    if (github.enabled && github.role == BackendRole.primary) return github;
    if (gitee.enabled && gitee.role == BackendRole.primary) return gitee;
    if (webdav.enabled && webdav.role == BackendRole.primary) return webdav;
    return null;
  }

  /// 返回所有启用的 mirror 后端。
  List<BackendConfig> get mirrorBackends {
    if (!cloudEnabled) return const [];
    final out = <BackendConfig>[];
    if (github.enabled && github.role == BackendRole.mirror) out.add(github);
    if (gitee.enabled && gitee.role == BackendRole.mirror) out.add(gitee);
    if (webdav.enabled && webdav.role == BackendRole.mirror) out.add(webdav);
    return out;
  }

  Future<void> setCloudEnabled(bool v) async {
    await _prefs.setBool(_kCloudEnabled, v);
    notifyListeners();
  }

  Future<void> setAutoSyncOnLaunch(bool v) async {
    await _prefs.setBool(_kAutoSyncOnLaunch, v);
    notifyListeners();
  }

  Future<void> setPushAfterEdit(bool v) async {
    await _prefs.setBool(_kPushAfterEdit, v);
    notifyListeners();
  }

  Future<void> updateBackend(BackendConfig config) async {
    final key = switch (config.kind) {
      BackendKind.github => _kBackendGithub,
      BackendKind.gitee => _kBackendGitee,
      BackendKind.webdav => _kBackendWebDav,
    };
    await _prefs.setString(key, _encode(config.toJson()));
    notifyListeners();
  }

  static Map<String, Object?> _decode(String raw) =>
      (jsonDecode(raw) as Map).cast<String, Object?>();
  static String _encode(Map<String, Object?> m) => jsonEncode(m);
}
