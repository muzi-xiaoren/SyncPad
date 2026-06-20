import 'settings/app_settings.dart';
import 'settings/secure_credential_store.dart';
import 'storage/attachment_store.dart';
import 'storage/compactor.dart';
import 'storage/note_repository.dart';
import 'sync/sync_manager.dart';

/// 整个 app 共享的运行时依赖容器。通过 Provider 注入到 UI。
class AppState {
  AppState({
    required this.repo,
    required this.settings,
    required this.credentials,
    required this.sync,
    required this.compactor,
    required this.attachments,
  });

  final NoteRepository repo;
  final AppSettings settings;
  final SecureCredentialStore credentials;
  final SyncManager sync;
  final Compactor compactor;
  final AttachmentStore attachments;

  /// 编辑/删除后按设置自动推送（关云同步或关开关时静默跳过）。失败不抛。
  Future<void> maybePushAfterEdit(String commitMessage) async {
    if (!settings.cloudEnabled || !settings.pushAfterEdit) return;
    try {
      await sync.pushAll(commitMessage: commitMessage);
    } catch (_) {
      // 推送失败不影响本地编辑；状态已记录在 SyncManager.status 里。
    }
  }
}
