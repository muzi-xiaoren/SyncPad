import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BackendKind { github, gitee, webdav }

enum BackendRole { primary, mirror }

/// 笔记排序方式。
enum NoteSort { updatedDesc, createdDesc, titleAsc }

/// 笔记列表布局：宫格(masonry) / 列表。
enum NoteLayout { grid, list }

/// 笔记内容文字大小。
enum TextSizePref { small, normal, large }

extension TextSizePrefScale on TextSizePref {
  double get scale => switch (this) {
        TextSizePref.small => 0.9,
        TextSizePref.normal => 1.0,
        TextSizePref.large => 1.2,
      };
}

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
  static const _kSort = 'note_sort';
  static const _kLayout = 'note_layout';
  static const _kTextSize = 'note_text_size';
  static const _kLivePreview = 'md_live_preview';
  static const _kAutoCompactBeforeSync = 'auto_compact_before_sync';
  static const _kWindowFrame = 'window_frame';

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

  NoteSort get sort => NoteSort.values.firstWhere(
        (e) => e.name == _prefs.getString(_kSort),
        orElse: () => NoteSort.updatedDesc,
      );

  NoteLayout get layout => NoteLayout.values.firstWhere(
        (e) => e.name == _prefs.getString(_kLayout),
        orElse: () => NoteLayout.grid,
      );

  TextSizePref get textSize => TextSizePref.values.firstWhere(
        (e) => e.name == _prefs.getString(_kTextSize),
        orElse: () => TextSizePref.normal,
      );

  /// 编辑笔记时块级“所见即所得”实时预览（Typora 式）。默认开。
  bool get livePreview => _prefs.getBool(_kLivePreview) ?? true;

  /// 推送前若日志放大率过高自动整理一次。默认开。
  bool get autoCompactBeforeSync =>
      _prefs.getBool(_kAutoCompactBeforeSync) ?? true;

  /// 桌面窗口几何 [left, top, width, height]；无记录返回 null。
  List<double>? get windowFrame {
    final raw = _prefs.getString(_kWindowFrame);
    if (raw == null) return null;
    final parts = raw.split(',').map(double.tryParse).toList();
    if (parts.length != 4 || parts.any((e) => e == null)) return null;
    return parts.cast<double>();
  }

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

  Future<void> setSort(NoteSort v) async {
    await _prefs.setString(_kSort, v.name);
    notifyListeners();
  }

  Future<void> setLayout(NoteLayout v) async {
    await _prefs.setString(_kLayout, v.name);
    notifyListeners();
  }

  Future<void> setTextSize(TextSizePref v) async {
    await _prefs.setString(_kTextSize, v.name);
    notifyListeners();
  }

  Future<void> setLivePreview(bool v) async {
    await _prefs.setBool(_kLivePreview, v);
    notifyListeners();
  }

  Future<void> setAutoCompactBeforeSync(bool v) async {
    await _prefs.setBool(_kAutoCompactBeforeSync, v);
    notifyListeners();
  }

  /// 保存窗口几何。不 notifyListeners：窗口位置/大小变化不影响 UI。
  Future<void> setWindowFrame(
      double left, double top, double width, double height) async {
    await _prefs.setString(_kWindowFrame, '$left,$top,$width,$height');
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
