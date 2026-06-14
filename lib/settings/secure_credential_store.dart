import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_settings.dart';

/// PAT / 应用密码走 OS Keychain：Android Keystore / macOS Keychain / Windows DPAPI。
class SecureCredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // macOS：关掉"数据保护钥匙串"，改用传统登录钥匙串，
              // 这样 adhoc 自签（无 keychain-access-groups 授权）也能读写。
              mOptions: MacOsOptions(useDataProtectionKeyChain: false),
            );

  final FlutterSecureStorage _storage;

  static String _key(BackendKind kind) => switch (kind) {
        BackendKind.github => 'pat_github',
        BackendKind.gitee => 'pat_gitee',
        BackendKind.webdav => 'password_webdav',
      };

  Future<String?> readPat(BackendKind kind) => _storage.read(key: _key(kind));

  Future<void> writePat(BackendKind kind, String pat) =>
      _storage.write(key: _key(kind), value: pat);

  Future<void> deletePat(BackendKind kind) => _storage.delete(key: _key(kind));

  Future<bool> hasPat(BackendKind kind) async =>
      (await readPat(kind))?.isNotEmpty ?? false;
}
