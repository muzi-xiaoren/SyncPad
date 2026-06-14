import 'package:flutter/material.dart';

/// 笔记/待办卡片的配色板。index 0 = 默认（跟随主题），1..8 为柔和色。
class NotePalette {
  static const int count = 9;

  // 浅色模式背景（柔和粉彩）
  static const List<int?> _light = [
    null,
    0xFFFFEBEE, // 红
    0xFFFFF3E0, // 橙
    0xFFFFF8E1, // 黄
    0xFFE8F5E9, // 绿
    0xFFE0F2F1, // 青
    0xFFE3F2FD, // 蓝
    0xFFF3E5F5, // 紫
    0xFFECEFF1, // 灰
  ];

  // 深色模式背景（加深、低饱和）
  static const List<int?> _dark = [
    null,
    0xFF4E3434,
    0xFF4A3A2A,
    0xFF4A442A,
    0xFF2E4034,
    0xFF26403E,
    0xFF2A3A4A,
    0xFF3C2E44,
    0xFF37404A,
  ];

  /// 卡片背景色；index 0（默认）返回 null，由调用方用主题默认卡片色。
  static Color? background(int index, Brightness brightness) {
    final list = brightness == Brightness.dark ? _dark : _light;
    if (index < 0 || index >= list.length) return null;
    final v = list[index];
    return v == null ? null : Color(v);
  }

  /// 调色板里展示的色块（默认项也给一个可见色，便于点选）。
  static Color swatch(int index, Brightness brightness) =>
      background(index, brightness) ??
      (brightness == Brightness.dark
          ? const Color(0xFF3A3A3A)
          : const Color(0xFFFFFFFF));
}
