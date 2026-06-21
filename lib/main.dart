import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'desktop/window_state.dart';
import 'settings/app_settings.dart';
import 'settings/secure_credential_store.dart';
import 'storage/attachment_store.dart';
import 'storage/compactor.dart';
import 'storage/note_repository.dart';
import 'sync/sync_manager.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await AppSettings.load();

  // 桌面端：恢复上次窗口位置/大小（移动端跳过）。
  if (isDesktop) {
    await WindowStateManager(settings).initAndRestore();
  }

  final credentials = SecureCredentialStore();
  final repo = await NoteRepository.open();
  // 清理删除满 30 天的回收站条目（Apple Notes 同款保留期）。
  await repo.purgeExpiredTrash();
  final attachments = await AttachmentStore.open();
  final compactor = Compactor(repo.store, repo.index);
  final sync = SyncManager(
    settings: settings,
    credentials: credentials,
    logStore: repo.store,
    memoryIndex: repo.index,
    attachments: attachments,
    compactor: compactor,
  );

  final appState = AppState(
    repo: repo,
    settings: settings,
    credentials: credentials,
    sync: sync,
    compactor: compactor,
    attachments: attachments,
  );

  // 启动时按设置自动拉取合并（失败静默，仅记录状态）。
  if (settings.autoSyncOnLaunch) {
    // ignore: discarded_futures
    sync.pullAndMerge();
  } else {
    // ignore: discarded_futures
    sync.checkRemoteAsync();
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<AppState>.value(value: appState),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: repo.index),
      ],
      child: const SyncPadApp(),
    ),
  );
}

class SyncPadApp extends StatelessWidget {
  const SyncPadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncPad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D6B),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D6B),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}
