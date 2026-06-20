import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../settings/app_settings.dart';
import '../storage/memory_index.dart';
import '../sync/git_backend.dart';
import '../sync/sync_backend.dart';
import '../sync/webdav_backend.dart';
import 'trash_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // ============ 云同步 ============
          const _SectionHeader('云同步'),
          SwitchListTile(
            title: const Text('启用云同步'),
            subtitle: const Text('把加密日志同步到 GitHub / Gitee / WebDAV'),
            value: settings.cloudEnabled,
            onChanged: settings.setCloudEnabled,
          ),
          if (settings.cloudEnabled) ...[
            const _BackendTile(kind: BackendKind.github),
            const _BackendTile(kind: BackendKind.gitee),
            const _BackendTile(kind: BackendKind.webdav),
            const Divider(),
            SwitchListTile(
              title: const Text('启动时自动拉取'),
              subtitle: const Text('打开应用时自动从远端合并最新内容'),
              value: settings.autoSyncOnLaunch,
              onChanged: settings.setAutoSyncOnLaunch,
            ),
            SwitchListTile(
              title: const Text('编辑后自动推送'),
              subtitle: const Text('新增/修改/删除后自动推送到远端'),
              value: settings.pushAfterEdit,
              onChanged: settings.setPushAfterEdit,
            ),
            const Divider(),
            const _SectionHeader('手动覆盖（谨慎）'),
            ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('用云端覆盖本地'),
              subtitle: const Text('丢弃本地改动，完全采用远端内容'),
              onTap: () => _overwriteLocal(context),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('用本地覆盖云端'),
              subtitle: const Text('强制把本地内容推到远端，覆盖远端'),
              onTap: () => _overwriteRemote(context),
            ),
          ],

          const Divider(),
          // ============ 笔记样式 ============
          const _SectionHeader('笔记样式'),
          ListTile(
            leading: const Icon(Icons.format_size),
            title: const Text('文字大小'),
            trailing: DropdownButton<TextSizePref>(
              value: settings.textSize,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) settings.setTextSize(v);
              },
              items: const [
                DropdownMenuItem(value: TextSizePref.small, child: Text('较小')),
                DropdownMenuItem(value: TextSizePref.normal, child: Text('默认')),
                DropdownMenuItem(value: TextSizePref.large, child: Text('较大')),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.sort),
            title: const Text('排序方式'),
            trailing: DropdownButton<NoteSort>(
              value: settings.sort,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) settings.setSort(v);
              },
              items: const [
                DropdownMenuItem(
                    value: NoteSort.updatedDesc, child: Text('按修改时间')),
                DropdownMenuItem(
                    value: NoteSort.createdDesc, child: Text('按创建时间')),
                DropdownMenuItem(value: NoteSort.titleAsc, child: Text('按标题')),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.grid_view),
            title: const Text('笔记列表布局'),
            trailing: DropdownButton<NoteLayout>(
              value: settings.layout,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) settings.setLayout(v);
              },
              items: const [
                DropdownMenuItem(value: NoteLayout.grid, child: Text('宫格')),
                DropdownMenuItem(value: NoteLayout.list, child: Text('列表')),
              ],
            ),
          ),

          const Divider(),
          // ============ 数据 ============
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('最近删除'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TrashPage())),
          ),

          const Divider(),
          // ============ 维护 ============
          const _SectionHeader('维护'),
          ListTile(
            leading: const Icon(Icons.compress),
            title: const Text('立即整理日志'),
            subtitle: const _CompactionSubtitle(),
            onTap: () => _runCompaction(context),
          ),

          const Divider(),
          const _SectionHeader('关于'),
          const _AboutSection(),
        ],
      ),
    );
  }

  Future<void> _overwriteLocal(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirm(context, '用云端覆盖本地',
        '将丢弃本地未推送的改动，完全采用远端内容。确定吗？');
    if (ok != true) return;
    await app.sync.overwriteLocalWithRemote();
    messenger.showSnackBar(
      SnackBar(content: Text(app.sync.status.message ?? '完成')),
    );
  }

  Future<void> _overwriteRemote(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirm(context, '用本地覆盖云端',
        '将强制把本地内容推到远端，覆盖远端现有内容。确定吗？');
    if (ok != true) return;
    await app.sync.overwriteRemoteWithLocal();
    messenger.showSnackBar(
      SnackBar(content: Text(app.sync.status.message ?? '完成')),
    );
  }

  Future<void> _runCompaction(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    // 协议：先 pull 再 compact 再 push（避免压实把未同步的远端改动丢掉）。
    if (app.settings.cloudEnabled) {
      await app.sync.pullAndMerge();
    }
    final report = await app.compactor.compact();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
            '已整理：${report.activeRecords} 条笔记，节省 ${_humanBytes(report.savedBytes)}'),
      ),
    );
    if (app.settings.cloudEnabled) {
      await app.sync.pushAll(commitMessage: 'compact log');
    }
  }
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定')),
      ],
    ),
  );
}

String _humanBytes(int n) {
  if (n < 1024) return '${n}B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _CompactionSubtitle extends StatelessWidget {
  const _CompactionSubtitle();

  @override
  Widget build(BuildContext context) {
    final ix = context.watch<MemoryIndex>();
    final amp = ix.amplification.toStringAsFixed(2);
    return Text('${ix.activeCount} 条笔记 / ${ix.totalLineCount} 行日志（放大率 $amp）');
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, size: 20),
              const SizedBox(width: 8),
              Text('SyncPad', style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          const Text('版本 0.4.0'),
          const SizedBox(height: 4),
          const Text('本地优先 · 免费 Git/WebDAV 云同步的开源记事本'),
          const SizedBox(height: 8),
          SelectableText(
            '数据文件：${app.repo.store.path}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

// ============ 后端配置卡（移植自 PassPro） ============

class _BackendTile extends StatelessWidget {
  const _BackendTile({required this.kind});

  final BackendKind kind;

  String get _name => switch (kind) {
        BackendKind.github => 'GitHub',
        BackendKind.gitee => 'Gitee',
        BackendKind.webdav => 'WebDAV',
      };

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final cfg = switch (kind) {
      BackendKind.github => settings.github,
      BackendKind.gitee => settings.gitee,
      BackendKind.webdav => settings.webdav,
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        leading: Icon(
          kind == BackendKind.github ? Icons.code : Icons.cloud_outlined,
        ),
        title: Text(_name),
        subtitle: Text(
          cfg.enabled
              ? '${cfg.role == BackendRole.primary ? '主仓库' : '副仓库'} · ${kind == BackendKind.webdav ? cfg.repo : "${cfg.owner}/${cfg.repo}"}'
              : '未启用',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _BackendForm(initial: cfg),
          ),
        ],
      ),
    );
  }
}

class _BackendForm extends StatefulWidget {
  const _BackendForm({required this.initial});
  final BackendConfig initial;

  @override
  State<_BackendForm> createState() => _BackendFormState();
}

class _BackendFormState extends State<_BackendForm> {
  late bool _enabled;
  late BackendRole _role;
  late final TextEditingController _owner;
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late final TextEditingController _filePath;
  late final TextEditingController _pat;
  bool _patChanged = false;
  bool _testing = false;
  String? _testMessage;
  bool _testFailed = false;

  bool get _isWebDav => widget.initial.kind == BackendKind.webdav;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initial.enabled;
    _role = widget.initial.role;
    _owner = TextEditingController(text: widget.initial.owner);
    _repo = TextEditingController(text: widget.initial.repo);
    _branch = TextEditingController(text: widget.initial.branch);
    _filePath = TextEditingController(text: widget.initial.filePath);
    _pat = TextEditingController();
    _loadPat();
  }

  Future<void> _loadPat() async {
    final app = context.read<AppState>();
    final existing = await app.credentials.readPat(widget.initial.kind);
    if (existing != null && existing.isNotEmpty && mounted) {
      _pat.text = '••••••••';
    }
  }

  @override
  void dispose() {
    _owner.dispose();
    _repo.dispose();
    _branch.dispose();
    _filePath.dispose();
    _pat.dispose();
    super.dispose();
  }

  BackendConfig _currentConfig() => widget.initial.copyWith(
        enabled: _enabled,
        role: _role,
        owner: _owner.text.trim(),
        repo: _repo.text.trim(),
        branch: _branch.text.trim().isEmpty
            ? BackendConfig.defaultBranchFor(widget.initial.kind)
            : _branch.text.trim(),
        filePath: _filePath.text.trim().isEmpty
            ? BackendConfig.defaultFilePathFor(widget.initial.kind)
            : _filePath.text.trim(),
      );

  Future<void> _save() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.settings.updateBackend(_currentConfig());
      final pat = _pat.text.trim();
      if (_patChanged && pat.isNotEmpty && pat != '••••••••') {
        await app.credentials.writePat(widget.initial.kind, pat);
      }
      messenger.showSnackBar(const SnackBar(content: Text('已保存')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    final app = context.read<AppState>();
    var pat = _pat.text.trim();
    if (pat == '••••••••' || pat.isEmpty) {
      pat = (await app.credentials.readPat(widget.initial.kind) ?? '').trim();
    }
    final cfg = _currentConfig().copyWith(enabled: true);
    try {
      final backend = _isWebDav
          ? WebDavBackend(config: cfg, password: pat)
          : GitBackend(config: cfg, pat: pat);
      final v = await backend.testConnection();
      if (!mounted) return;
      setState(() {
        _testFailed = false;
        final shortVersion =
            v == null || v.length <= 7 ? v : v.substring(0, 7);
        _testMessage = v == null
            ? '连接成功（远端暂无文件，首次推送会创建）'
            : '连接成功（版本 $shortVersion）';
      });
    } on SyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testMessage = switch (e.kind) {
          SyncErrorKind.repoNotFound =>
            '仓库不存在或令牌无权访问：${cfg.owner}/${cfg.repo}',
          SyncErrorKind.webdavFolderMissing =>
            '目标文件夹不存在，请先在坚果云里手动创建对应文件夹',
          SyncErrorKind.http =>
            '失败 HTTP ${e.statusCode ?? '-'}：${e.message}',
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testMessage = '失败：$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('启用此后端'),
          value: _enabled,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        Row(
          children: [
            const Text('角色'),
            const SizedBox(width: 12),
            SegmentedButton<BackendRole>(
              segments: const [
                ButtonSegment(value: BackendRole.primary, label: Text('主仓库')),
                ButtonSegment(value: BackendRole.mirror, label: Text('副仓库')),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _owner,
          decoration: InputDecoration(
            labelText: _isWebDav ? '账户（邮箱）' : 'Owner（命名空间）',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _repo,
          decoration: InputDecoration(
            labelText: _isWebDav ? '服务器地址' : '仓库名',
            hintText: _isWebDav ? 'https://dav.jianguoyun.com/dav/' : null,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (!_isWebDav) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _branch,
            decoration: const InputDecoration(
              labelText: '分支',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _filePath,
          decoration: InputDecoration(
            labelText: _isWebDav ? '远程文件路径' : '文件路径',
            hintText: _isWebDav ? '/SyncPad/notes.log' : 'notes.log',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pat,
          obscureText: true,
          onChanged: (_) => _patChanged = true,
          onTap: () {
            if (_pat.text == '••••••••') _pat.clear();
            _patChanged = true;
          },
          decoration: InputDecoration(
            labelText: _isWebDav ? '应用密码' : 'Access Token',
            helperText: _isWebDav
                ? '坚果云：账户设置 → 安全选项 → 第三方应用管理 生成'
                : 'GitHub/Gitee 的私有令牌（需仓库读写权限）',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (_testMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _testMessage!,
            style: TextStyle(
              color: _testFailed
                  ? Theme.of(context).colorScheme.error
                  : Colors.green,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              label: const Text('测试连接'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ],
        ),
      ],
    );
  }
}
