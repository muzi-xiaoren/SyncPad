import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import '../storage/memory_index.dart';
import '../sync/sync_manager.dart';
import 'edit_note_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _openNote(BuildContext context, String? id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditNotePage(noteId: id)),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Note note) async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定删除「${note.title.isEmpty ? '(无标题)' : note.title}」吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await app.repo.deleteById(note.id);
    await app.maybePushAfterEdit('delete note');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('SyncPad'),
        actions: [
          const _SyncButton(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _query,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索标题或正文…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _query.clear()),
                      ),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          Expanded(
            child: Consumer<MemoryIndex>(
              builder: (context, _, _) {
                final notes = app.repo.search(_query.text);
                if (notes.isEmpty) {
                  return _EmptyState(searching: _query.text.isNotEmpty);
                }
                return ListView.separated(
                  itemCount: notes.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final note = notes[i];
                    return ListTile(
                      title: Text(
                        note.title.isEmpty ? '(无标题)' : note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${_formatTime(note.updatedAt)}'
                        '${note.preview.isEmpty ? '' : '  ·  ${note.preview}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _openNote(context, note.id),
                      onLongPress: () => _confirmDelete(context, note),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNote(context, null),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// AppBar 上的同步按钮：展示当前同步状态图标，点按触发"拉取+推送"。
class _SyncButton extends StatelessWidget {
  const _SyncButton();

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncManager>();
    final app = context.read<AppState>();
    final state = sync.status.state;

    if (state == SyncState.working) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final (icon, tip) = switch (state) {
      SyncState.ok => (Icons.cloud_done_outlined, '已同步'),
      SyncState.error => (Icons.cloud_off_outlined, '同步出错'),
      SyncState.offline => (Icons.cloud_off_outlined, '离线'),
      _ => (Icons.cloud_sync_outlined, '同步'),
    };

    return IconButton(
      icon: Icon(icon),
      tooltip: tip,
      onPressed: () async {
        if (!app.settings.cloudEnabled) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请先在设置里开启云同步并配置仓库')),
          );
          return;
        }
        final messenger = ScaffoldMessenger.of(context);
        await app.sync.pullAndMerge();
        await app.sync.pushAll();
        messenger.showSnackBar(
          SnackBar(content: Text(app.sync.status.message ?? '同步完成')),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searching});
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(searching ? Icons.search_off : Icons.note_add_outlined,
              size: 56, color: color),
          const SizedBox(height: 12),
          Text(
            searching ? '没有匹配的笔记' : '还没有笔记，点右下角 + 新建一条',
            style: TextStyle(color: color),
          ),
        ],
      ),
    );
  }
}

String _formatTime(DateTime utc) {
  final t = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
