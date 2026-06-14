import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import '../storage/memory_index.dart';
import 'note_actions.dart';

/// 回收站：列出软删除的笔记/待办，可恢复或彻底删除。
class TrashPage extends StatelessWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    context.watch<MemoryIndex>();
    final items = app.repo.index.trashed();

    return Scaffold(
      appBar: AppBar(
        title: const Text('最近删除'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清空回收站'),
                    content: const Text('将彻底删除回收站里的所有条目，无法恢复。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('清空')),
                    ],
                  ),
                );
                if (ok != true) return;
                await app.repo.emptyTrash();
                await app.maybePushAfterEdit('empty trash');
                messenger.showSnackBar(
                    const SnackBar(content: Text('已清空回收站')));
              },
              child: const Text('清空'),
            ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline,
                      size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('回收站是空的',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            )
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = items[i];
                return ListTile(
                  leading: Icon(n.isTodo
                      ? Icons.checklist
                      : Icons.sticky_note_2_outlined),
                  title: Text(
                    n.title.isEmpty
                        ? (n.preview.isEmpty ? '(无标题)' : n.preview)
                        : n.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('删除于 ${formatNoteTime(n.deletedAt ?? n.updatedAt)}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '恢复',
                        icon: const Icon(Icons.restore),
                        onPressed: () async {
                          await app.repo.restore(n.id);
                          await app.maybePushAfterEdit('restore note');
                        },
                      ),
                      IconButton(
                        tooltip: '彻底删除',
                        icon: const Icon(Icons.delete_forever_outlined),
                        onPressed: () => _deleteForever(context, app, n),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _deleteForever(
      BuildContext context, AppState app, Note n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: const Text('该条目将无法恢复，确定吗？'),
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
    await app.repo.deleteForever(n.id);
    await app.maybePushAfterEdit('delete forever');
  }
}
