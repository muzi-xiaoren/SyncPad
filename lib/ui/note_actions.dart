import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import 'note_palette.dart';

/// 调色板：返回选中的色板索引，取消则 null。
Future<int?> pickColorIndex(BuildContext context, int current) {
  final brightness = Theme.of(context).brightness;
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (var i = 0; i < NotePalette.count; i++)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, i),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: NotePalette.swatch(i, brightness),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: current == i
                          ? Theme.of(ctx).colorScheme.primary
                          : Theme.of(ctx).dividerColor,
                      width: current == i ? 3 : 1,
                    ),
                  ),
                  child:
                      current == i ? const Icon(Icons.check, size: 20) : null,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 选择/新建文件夹：返回文件夹名（'' = 未分类），取消则 null。
Future<String?> pickFolderName(
  BuildContext context, {
  required String current,
  required List<String> folders,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('未分类'),
            trailing: current.isEmpty ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final f in folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(f),
              trailing: current == f ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, f),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('新建文件夹…'),
            onTap: () async {
              final name = await promptNewFolder(ctx);
              if (name != null && name.isNotEmpty && ctx.mounted) {
                Navigator.pop(ctx, name);
              }
            },
          ),
        ],
      ),
    ),
  );
}

/// 长按卡片弹出的操作菜单：置顶 / 改色 / 移动文件夹 / 删除。
Future<void> showNoteActions(BuildContext context, Note note) async {
  final app = context.read<AppState>();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading:
                Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
            title: Text(note.pinned ? '取消置顶' : '置顶'),
            onTap: () async {
              Navigator.pop(ctx);
              await app.repo.togglePinned(note.id);
              await app.maybePushAfterEdit('pin note');
            },
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('更改颜色'),
            onTap: () async {
              Navigator.pop(ctx);
              await chooseColor(context, note);
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('移动到文件夹'),
            subtitle: Text(note.folder.isEmpty ? '未分类' : note.folder),
            onTap: () async {
              Navigator.pop(ctx);
              await chooseFolderForMove(context, note);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('创建副本'),
            onTap: () async {
              Navigator.pop(ctx);
              await app.repo.duplicate(note.id);
              await app.maybePushAfterEdit('duplicate note');
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('删除'),
            onTap: () async {
              Navigator.pop(ctx);
              await trashWithUndo(context, note);
            },
          ),
        ],
      ),
    ),
  );
}

/// 把条目移到回收站，并弹出可一键撤销的提示（SnackBar）。
///
/// 所有“删除”入口（长按菜单、编辑页）都走这里，保证撤销体验一致。
Future<void> trashWithUndo(BuildContext context, Note note) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  await app.repo.moveToTrash(note.id);
  await app.maybePushAfterEdit('trash note');
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: const Text('已移到回收站'),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          await app.repo.restore(note.id);
          await app.maybePushAfterEdit('undo trash');
        },
      ),
    ));
}

Future<void> chooseColor(BuildContext context, Note note) async {
  final app = context.read<AppState>();
  final picked = await pickColorIndex(context, note.color);
  if (picked != null) {
    await app.repo.setColor(note.id, picked);
    await app.maybePushAfterEdit('color note');
  }
}

Future<void> chooseFolderForMove(BuildContext context, Note note) async {
  final app = context.read<AppState>();
  final picked = await pickFolderName(
    context,
    current: note.folder,
    folders: app.repo.index.folders(),
  );
  if (picked != null) {
    await app.repo.setFolder(note.id, picked);
    await app.maybePushAfterEdit('move note');
  }
}

/// 新建文件夹的输入弹窗，返回名称或 null。
Future<String?> promptNewFolder(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('新建文件夹'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '文件夹名称'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建')),
      ],
    ),
  );
}

/// 把 UTC 时间格式化为本地的相对/绝对显示。
String formatNoteTime(DateTime utc) {
  final t = utc.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  String two(int n) => n.toString().padLeft(2, '0');
  final diff = today.difference(that).inDays;
  if (diff == 0) return '${two(t.hour)}:${two(t.minute)}';
  if (diff == 1) return '昨天';
  if (t.year == now.year) return '${t.month}月${t.day}日';
  return '${t.year}年${t.month}月${t.day}日';
}
