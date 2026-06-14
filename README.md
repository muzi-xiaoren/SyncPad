# SyncPad

跨平台、本地优先的开源记事本，内置**免费的 Git / WebDAV 云同步**。

> 架构脱胎于 [PassPro](../PassPro)（密码管理器）：同样的 append-only 行式日志 + 内存索引 +
> 主备同步，只是把"密码条目"换成了"笔记"。

## 设计要点

- **本地优先**：所有笔记先落本地，断网照常读写；同步只是把本地日志在多端之间合并。
- **存储**：append-only 行式日志（一行一个操作）+ 内存索引，CRUD 全部 O(1)，启动一次性 replay。
- **整理**：放大率达到阈值或手动触发 compaction，把"操作历史"折叠成"最新快照"。
- **同步**：可选；支持 GitHub、Gitee、WebDAV / 坚果云，采用 **Primary + Mirror** 模式
  - Primary 是真相源，pull/push 都先走 primary；不可达时自动降级从 Mirror 拉取。
  - push 永远先写 Primary，再尽力推 Mirror（Mirror 冲突时自动 pull+merge+强制覆盖收敛）。
- **冲突合并**：按 `record_id` 做行级 union，同一条取时间戳较大者（"后写胜出"），DEL 最终成立。

> ⚠️ 合并是"**每篇笔记**"粒度，不是字符级。两端同时改同一篇笔记，较早那次会被覆盖
> （不会损坏数据，但会丢一次改动）。真正的并发文本合并需要 CRDT —— 见路线图。

## 为什么这套同步方案"一直免费 + 方便"

它**没有后端**：App 直接读写 GitHub/Gitee 现成的仓库 API、坚果云现成的 WebDAV。
你不用写、不用部署、不用维护任何服务器，云端就是"一个文件仓库"。

- GitHub 私有仓：无限个、认证后 5000 次/小时
- Gitee：免费且国内访问快
- 坚果云 WebDAV 免费版：每月上传 1GB / 下载 3GB、单文件 ≤500MB —— 纯文本笔记绰绰有余

## 数据存放位置

笔记日志文件名固定为 `notes.log`，位于各平台「应用支持目录」下的 `SyncPad/` 子目录中
（由 `path_provider` 的 `getApplicationSupportDirectory()` 决定）：

| 平台      | 实际路径 |
| ------- | ------- |
| macOS   | `~/Library/Application Support/com.syncpad.syncpad/SyncPad/notes.log` |
| Windows | `%APPDATA%\com.syncpad\syncpad\SyncPad\notes.log` |
| Linux   | `~/.local/share/syncpad/SyncPad/notes.log` |
| Android | 应用私有目录 `…/files/SyncPad/notes.log` |
| iOS     | 应用沙盒 `…/Library/Application Support/SyncPad/notes.log` |

> Token / 应用密码存于系统钥匙串（Android Keystore / macOS Keychain / Win DPAPI），不在上述目录里。
> v0.1 笔记内容以**明文**存放在你的（私有）仓库里；端到端加密见路线图。

## 目录结构

```
SyncPad/
├── lib/
│   ├── main.dart                    # 入口：装配依赖 + Provider
│   ├── app_state.dart               # 运行时依赖容器
│   ├── models/
│   │   └── note.dart                # Note + LogRecord（行式 JSON）
│   ├── storage/
│   │   ├── log_store.dart           # 磁盘日志读写（append / 原子 replace）
│   │   ├── memory_index.dart        # 内存索引 + 全文检索（ChangeNotifier）
│   │   ├── note_repository.dart     # CRUD API（UI 唯一入口）
│   │   ├── compactor.dart           # 压实
│   │   └── conflict_merger.dart     # 行级 union 合并
│   ├── sync/
│   │   ├── sync_backend.dart        # 抽象接口
│   │   ├── git_backend.dart         # GitHub / Gitee 共用实现
│   │   ├── webdav_backend.dart      # WebDAV / 坚果云实现
│   │   └── sync_manager.dart        # 主备调度 + 状态
│   ├── settings/
│   │   ├── app_settings.dart        # SharedPreferences
│   │   └── secure_credential_store.dart  # Token / 应用密码走 OS Keychain
│   └── ui/
│       ├── home_page.dart           # 笔记列表 + 搜索 + 同步按钮
│       ├── edit_note_page.dart      # 编辑（返回即保存）
│       └── settings_page.dart       # 云同步配置 + 维护 + 关于
├── test/
│   ├── merge_test.dart              # 合并 + 序列化往返
│   └── widget_test.dart             # 内存索引 + 检索
```

## 准备环境 & 运行

```bash
# 依赖
cd SyncPad
flutter pub get

# 跑测试 / 静态检查
flutter test
flutter analyze

# 本机运行
flutter run -d macos                 # 桌面调试（Windows/Linux 同理）
flutter run -d <android-device>      # 真机调试
```

## 打包

```bash
flutter build apk --release          # Android  → build/app/outputs/flutter-apk/
flutter build windows --release      # Windows  → build/windows/x64/runner/Release/
flutter build macos --release        # macOS    → build/macos/Build/Products/Release/
```

## 同步配置

进入「设置 → 云同步」，打开总开关后配置至少一个 **主仓库（Primary）**，可选再加 **副仓库（Mirror）** 备份。

### GitHub / Gitee
1. 新建一个**私有仓库**（Gitee 无需勾选「初始化仓库」，首次推送自动创建文件与分支）。
2. 创建令牌：GitHub 用 Fine-grained token（仅该仓库 + Contents 读写）；Gitee 私人令牌勾 `projects`。
3. 填写 Owner（地址里的命名空间，不是昵称）、仓库名、分支（GitHub `main` / Gitee `master`）、
   文件路径 `notes.log`、Token，点「测试连接」。

### WebDAV / 坚果云
1. 坚果云「账户设置 → 安全选项 → 第三方应用管理」创建**应用密码**。
2. **先在坚果云里手动建好同步文件夹**（如 `SyncPad`）——坚果云不能通过 WebDAV 自动建顶层文件夹。
3. 填写账户（邮箱）、服务器 `https://dav.jianguoyun.com/dav/`、远程路径 `/SyncPad/notes.log`、应用密码。

## 路线图

- [ ] **端到端加密**：把 PassPro 的 `FernetCrypto` 搬过来对 `body` 加密（日志格式不变，仅密文化 `b` 字段）。
- [ ] **CRDT 文本合并**（Yjs / Automerge）：真正的并发编辑无损合并。
- [ ] Markdown 预览 / 标签 / 文件夹。
- [ ] 多语言 i18n（当前界面为简体中文）。
- [ ] 桌面窗口位置记忆、同步前后提示等 PassPro 已有的体验细节。

## 许可证

[MIT](LICENSE)
