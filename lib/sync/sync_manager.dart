import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/note.dart';
import '../settings/app_settings.dart';
import '../settings/secure_credential_store.dart';
import '../storage/attachment_store.dart';
import '../storage/compactor.dart';
import '../storage/conflict_merger.dart';
import '../storage/log_store.dart';
import '../storage/memory_index.dart';
import 'git_backend.dart';
import 'sync_backend.dart';
import 'webdav_backend.dart';

/// 同步状态供 UI 展示。
enum SyncState { idle, working, ok, offline, error }

/// 单个副仓库(mirror)的推送结果。
enum MirrorOutcome { ok, conflict, failed }

class MirrorResult {
  final String backend; // github / gitee / webdav
  final MirrorOutcome outcome;
  final String? detail;
  const MirrorResult(this.backend, this.outcome, {this.detail});
}

class SyncStatus {
  final SyncState state;
  final String? message;
  final List<MirrorResult> mirrors;
  final DateTime? lastSyncAt;
  final String? lastRemoteVersion;

  const SyncStatus({
    this.state = SyncState.idle,
    this.message,
    this.mirrors = const [],
    this.lastSyncAt,
    this.lastRemoteVersion,
  });

  SyncStatus copyWith({
    SyncState? state,
    String? message,
    List<MirrorResult>? mirrors,
    DateTime? lastSyncAt,
    String? lastRemoteVersion,
  }) {
    return SyncStatus(
      state: state ?? this.state,
      message: message ?? this.message,
      mirrors: mirrors ?? this.mirrors,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastRemoteVersion: lastRemoteVersion ?? this.lastRemoteVersion,
    );
  }
}

/// 主备策略调度：
///   pull → 优先 primary，失败/不可达自动降级到 mirror
///   push → primary 必须成功，mirror 失败仅 warning
class SyncManager extends ChangeNotifier {
  SyncManager({
    required this.settings,
    required this.credentials,
    required this.logStore,
    required this.memoryIndex,
    required this.attachments,
    this.compactor,
  });

  final AppSettings settings;
  final SecureCredentialStore credentials;
  final LogStore logStore;
  final MemoryIndex memoryIndex;
  final AttachmentStore attachments;

  /// 推送前自动整理日志用（可空：未注入时不自动整理）。
  final Compactor? compactor;

  SyncStatus _status = const SyncStatus();
  SyncStatus get status => _status;

  String? _knownRemoteVersion;

  /// 远端是否比上次同步更新（true=应提示拉取；null=未知/无法检测）。
  bool? remoteHasUpdates;

  void _setStatus(SyncStatus s) {
    _status = s;
    notifyListeners();
  }

  Future<SyncBackend?> _resolveBackend(BackendConfig cfg) async {
    if (!cfg.enabled) return null;
    final secret = await credentials.readPat(cfg.kind);
    if (secret == null || secret.isEmpty) return null;
    if (cfg.owner.isEmpty || cfg.repo.isEmpty || cfg.filePath.isEmpty) {
      return null;
    }
    return switch (cfg.kind) {
      BackendKind.github ||
      BackendKind.gitee =>
        GitBackend(config: cfg, pat: secret),
      BackendKind.webdav => WebDavBackend(config: cfg, password: secret),
    };
  }

  Future<SyncBackend?> _primary() async {
    final cfg = settings.primaryBackend;
    return cfg == null ? null : _resolveBackend(cfg);
  }

  Future<List<SyncBackend>> _mirrors() async {
    final out = <SyncBackend>[];
    for (final cfg in settings.mirrorBackends) {
      final b = await _resolveBackend(cfg);
      if (b != null) out.add(b);
    }
    return out;
  }

  /// 启动时异步探测：远端 head version 与上次记录是否一致。
  Future<void> checkRemoteAsync() async {
    if (!settings.cloudEnabled) {
      remoteHasUpdates = null;
      return;
    }
    try {
      final primary = await _primary();
      String? remoteVer;
      if (primary != null) {
        try {
          remoteVer = await primary.headVersion();
        } catch (_) {
          for (final m in await _mirrors()) {
            try {
              remoteVer = await m.headVersion();
              break;
            } catch (_) {/* try next */}
          }
        }
      }
      remoteHasUpdates = remoteVer != null && remoteVer != _knownRemoteVersion;
      _setStatus(_status.copyWith(lastRemoteVersion: remoteVer));
    } on SocketException {
      _setStatus(_status.copyWith(state: SyncState.offline));
    } catch (e) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '检测远端失败：$e',
      ));
    }
  }

  /// 拉取并合并到本地日志。返回是否实际产生了本地变化。
  Future<bool> pullAndMerge() async {
    if (!settings.cloudEnabled) return false;
    _setStatus(_status.copyWith(state: SyncState.working, message: '正在拉取…'));

    final primary = await _primary();
    final mirrors = await _mirrors();

    SyncBackend? used;
    RemoteSnapshot? snap;
    Object? lastError;
    for (final b in [?primary, ...mirrors]) {
      try {
        snap = await b.pull();
        used = b;
        break;
      } catch (e) {
        lastError = e;
        continue;
      }
    }

    if (snap == null || used == null) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '所有后端拉取失败：$lastError',
      ));
      return false;
    }

    if (!snap.exists || snap.content.isEmpty) {
      _knownRemoteVersion = snap.version;
      remoteHasUpdates = false;
      _setStatus(_status.copyWith(
        state: SyncState.ok,
        lastSyncAt: DateTime.now(),
        lastRemoteVersion: snap.version,
        message: '远端为空，无需合并',
      ));
      return false;
    }

    final remoteLog = _parseLog(snap.content);
    final localLog = await logStore.readAll();
    final merged = mergeLogs(localLog, remoteLog);
    final changed = !_logsEqual(merged, localLog);
    if (changed) {
      await logStore.replaceAll(merged);
      memoryIndex.replay(merged);
    }

    // 补齐被引用但本地缺失的附件（图片）。
    try {
      await _pullAttachmentsFrom(used);
    } catch (_) {}

    _knownRemoteVersion = snap.version;
    remoteHasUpdates = false;
    _setStatus(_status.copyWith(
      state: SyncState.ok,
      lastSyncAt: DateTime.now(),
      lastRemoteVersion: snap.version,
      message: '已从 ${used.name} 拉取',
    ));
    return changed;
  }

  /// 推送当前本地日志：primary 必成功，mirror 尽力。返回 true 表示 primary 写入成功。
  Future<bool> pushAll({
    String commitMessage = 'update notes',
    bool autoCompact = true,
  }) async {
    if (!settings.cloudEnabled) return false;

    // 同步前自动整理：日志放大率过高时先压实一次，避免越推越大。
    // 仅初次进入时尝试（冲突重试不再重复整理）；冲突由下面的 baseVersion 机制兜底，
    // 即便此时远端更新，重试会先 pull-merge 再推，不会丢数据。
    if (autoCompact &&
        settings.autoCompactBeforeSync &&
        compactor != null &&
        compactor!.shouldCompact()) {
      try {
        await compactor!.compact();
      } catch (_) {
        // 整理失败不影响推送，继续用当前日志。
      }
    }

    _setStatus(_status.copyWith(state: SyncState.working, message: '正在推送…'));

    final primary = await _primary();
    if (primary == null) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '未配置主仓库',
      ));
      return false;
    }

    final primaryName = primary.name;
    final localBytes = await _readLocalBytes();
    String? baseVersion;
    try {
      baseVersion = await primary.headVersion();
    } catch (_) {
      // 拉取 head 失败也不阻塞（仓库可能不存在文件）
    }

    PushOutcome outcome;
    try {
      outcome = await primary.push(
        content: localBytes,
        baseVersion: baseVersion,
        commitMessage: commitMessage,
      );
    } on SocketException catch (e) {
      _setStatus(_status.copyWith(
        state: SyncState.offline,
        message: '主仓库($primaryName)离线：$e',
      ));
      return false;
    } catch (e) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '主仓库($primaryName)推送失败：$e',
      ));
      return false;
    }

    if (outcome == PushOutcome.conflict) {
      // 远端比本地新：先拉合并，再重试一次
      final changed = await pullAndMerge();
      if (changed) {
        return pushAll(commitMessage: commitMessage, autoCompact: false);
      }
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '主仓库($primaryName)存在冲突，请手动拉取后再推送',
      ));
      return false;
    }

    final mirrors = await _pushMirrors(localBytes, commitMessage);

    // 把本地图片附件补齐到主仓库与副仓库（尽力，不阻塞）。
    await _pushAttachmentsEverywhere(primary);

    _knownRemoteVersion = await primary.headVersion();
    _setStatus(_status.copyWith(
      state: SyncState.ok,
      lastSyncAt: DateTime.now(),
      lastRemoteVersion: _knownRemoteVersion,
      message: '已推送到主仓库($primaryName)',
      mirrors: mirrors,
    ));
    return true;
  }

  /// 把本地内容尽力推送到每个 mirror，逐个返回结果（不抛异常）。
  Future<List<MirrorResult>> _pushMirrors(
    Uint8List localBytes,
    String commitMessage, {
    bool merge = true,
  }) async {
    final results = <MirrorResult>[];
    for (final m in await _mirrors()) {
      final name = m.name;
      try {
        String? mv;
        try {
          mv = await m.headVersion();
        } catch (_) {}
        var mo = await m.push(
          content: localBytes,
          baseVersion: mv,
          commitMessage: commitMessage,
        );
        if (mo == PushOutcome.conflict) {
          mo = await _resolveMirrorConflict(m, localBytes, commitMessage,
              merge: merge);
        }
        results.add(MirrorResult(
          name,
          mo == PushOutcome.conflict
              ? MirrorOutcome.conflict
              : MirrorOutcome.ok,
        ));
      } catch (e) {
        results.add(MirrorResult(name, MirrorOutcome.failed,
            detail: _shortError(e)));
      }
    }
    return results;
  }

  /// 副仓库冲突兜底：强制覆盖远端，消除坚果云 ETag 漂移造成的"假冲突"。
  ///   - [merge]=true：先拉远端与本地按 record_id 合并（任一端条目都不丢）再写。
  ///   - [merge]=false（"用本地覆盖云端"）：直接以本地内容覆盖。
  Future<PushOutcome> _resolveMirrorConflict(
    SyncBackend m,
    Uint8List localBytes,
    String commitMessage, {
    bool merge = true,
  }) async {
    final snap = await m.pull();
    var toPush = localBytes;
    if (merge && snap.exists && snap.content.isNotEmpty) {
      final merged = mergeLogs(_parseLog(localBytes), _parseLog(snap.content));
      toPush = _serializeLog(merged);
    }
    return m.push(
      content: toPush,
      baseVersion: snap.version,
      commitMessage: commitMessage,
      force: true,
    );
  }

  Uint8List _serializeLog(List<LogRecord> records) {
    final sb = StringBuffer();
    for (final r in records) {
      sb.writeln(r.toLine());
    }
    return Uint8List.fromList(utf8.encode(sb.toString()));
  }

  String _shortError(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  // ---- 附件（图片）同步：内容寻址，只“补齐缺失”，逐个尽力、不阻塞主流程 ----

  /// 把本地被引用、远端缺失的附件推到 [b]。返回成功推送数。
  Future<int> _pushAttachmentsTo(SyncBackend b) async {
    final referenced = memoryIndex.allAttachmentNames();
    if (referenced.isEmpty) return 0;
    Set<String> remote;
    try {
      remote = await b.listAttachments();
    } catch (_) {
      remote = {};
    }
    var n = 0;
    for (final name in referenced) {
      if (remote.contains(name)) continue;
      final bytes = await attachments.bytesForName(name);
      if (bytes == null) continue; // 本地也没有（可能别端的图还没拉到）
      try {
        await b.putAttachment(name, bytes);
        n++;
      } catch (_) {/* 单张失败不影响其它 */}
    }
    return n;
  }

  /// 从 [b] 拉取本地缺失但被引用的附件。返回成功拉取数。
  Future<int> _pullAttachmentsFrom(SyncBackend b) async {
    final referenced = memoryIndex.allAttachmentNames();
    if (referenced.isEmpty) return 0;
    final localHave = await attachments.localNames();
    var n = 0;
    for (final name in referenced) {
      if (localHave.contains(name)) continue;
      try {
        final bytes = await b.getAttachment(name);
        if (bytes != null) {
          await attachments.writeNamed(name, bytes);
          n++;
        }
      } catch (_) {/* 单张失败不影响其它 */}
    }
    return n;
  }

  /// 把附件推到主仓库 + 所有副仓库（尽力，吞掉异常）。
  Future<void> _pushAttachmentsEverywhere(SyncBackend primary) async {
    try {
      await _pushAttachmentsTo(primary);
    } catch (_) {}
    for (final m in await _mirrors()) {
      try {
        await _pushAttachmentsTo(m);
      } catch (_) {}
    }
  }

  /// 用云端覆盖本地：拉取远端快照并**完全替换**本地日志（不合并）。
  /// 远端不存在 / 为空时不执行（避免误清空本地）。
  Future<bool> overwriteLocalWithRemote() async {
    if (!settings.cloudEnabled) return false;
    _setStatus(_status.copyWith(state: SyncState.working, message: '正在拉取…'));

    final primary = await _primary();
    final mirrors = await _mirrors();

    SyncBackend? used;
    RemoteSnapshot? snap;
    Object? lastError;
    for (final b in [?primary, ...mirrors]) {
      try {
        snap = await b.pull();
        used = b;
        break;
      } catch (e) {
        lastError = e;
        continue;
      }
    }

    if (snap == null || used == null) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '所有后端拉取失败：$lastError',
      ));
      return false;
    }

    if (!snap.exists || snap.content.isEmpty) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '远端为空，已跳过（避免清空本地）',
      ));
      return false;
    }

    final remoteLog = _parseLog(snap.content);
    await logStore.replaceAll(remoteLog);
    memoryIndex.replay(remoteLog);

    // 补齐被引用但本地缺失的附件。
    try {
      await _pullAttachmentsFrom(used);
    } catch (_) {}

    _knownRemoteVersion = snap.version;
    remoteHasUpdates = false;
    _setStatus(_status.copyWith(
      state: SyncState.ok,
      lastSyncAt: DateTime.now(),
      lastRemoteVersion: snap.version,
      message: '已用 ${used.name} 的云端内容覆盖本地',
    ));
    return true;
  }

  /// 用本地覆盖云端：以远端**当前**版本为基线强制推送本地内容（覆盖远端，不合并）。
  Future<bool> overwriteRemoteWithLocal({
    String commitMessage = 'overwrite from local',
  }) async {
    if (!settings.cloudEnabled) return false;
    _setStatus(_status.copyWith(state: SyncState.working, message: '正在覆盖云端…'));

    final primary = await _primary();
    if (primary == null) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '未配置主仓库',
      ));
      return false;
    }

    final primaryName = primary.name;
    final localBytes = await _readLocalBytes();

    Future<PushOutcome> pushWithCurrentHead() async {
      String? head;
      try {
        head = await primary.headVersion();
      } catch (_) {}
      return primary.push(
        content: localBytes,
        baseVersion: head,
        commitMessage: commitMessage,
      );
    }

    PushOutcome outcome;
    try {
      outcome = await pushWithCurrentHead();
      if (outcome == PushOutcome.conflict) {
        outcome = await pushWithCurrentHead();
      }
    } on SocketException catch (e) {
      _setStatus(_status.copyWith(
        state: SyncState.offline,
        message: '主仓库($primaryName)离线：$e',
      ));
      return false;
    } catch (e) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '覆盖主仓库($primaryName)失败：$e',
      ));
      return false;
    }

    if (outcome == PushOutcome.conflict) {
      _setStatus(_status.copyWith(
        state: SyncState.error,
        message: '主仓库($primaryName)仍在变化，请稍后重试',
      ));
      return false;
    }

    final mirrors = await _pushMirrors(localBytes, commitMessage, merge: false);
    await _pushAttachmentsEverywhere(primary);

    _knownRemoteVersion = await primary.headVersion();
    _setStatus(_status.copyWith(
      state: SyncState.ok,
      lastSyncAt: DateTime.now(),
      lastRemoteVersion: _knownRemoteVersion,
      message: '已用本地内容覆盖主仓库($primaryName)',
      mirrors: mirrors,
    ));
    return true;
  }

  Future<Uint8List> _readLocalBytes() => logStore.file.readAsBytes();

  List<LogRecord> _parseLog(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final out = <LogRecord>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      try {
        out.add(LogRecord.fromLine(line));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  bool _logsEqual(List<LogRecord> a, List<LogRecord> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toLine() != b[i].toLine()) return false;
    }
    return true;
  }
}
