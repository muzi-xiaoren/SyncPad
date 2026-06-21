import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../settings/app_settings.dart';

/// 是否桌面平台（Windows / macOS / Linux）。移动端不触碰 window_manager。
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 记忆并恢复桌面窗口的位置与大小。
///
/// - 首次启动（无记录）：默认尺寸并居中。
/// - 之后启动：恢复上次关闭时的位置与大小。
/// - 拖动/缩放后持久化（连续事件防抖 + 手势结束立即落盘，兼容各平台差异）。
class WindowStateManager with WindowListener {
  WindowStateManager(this._settings);

  final AppSettings _settings;
  Timer? _debounce;

  static const Size _defaultSize = Size(960, 700);
  static const Size _minSize = Size(640, 480);

  /// 在 runApp 之前调用：初始化窗口并恢复上次几何。
  Future<void> initAndRestore() async {
    await windowManager.ensureInitialized();

    final saved = _settings.windowFrame;
    // 尺寸异常（小于最小值）视为无效，回退到默认并居中。
    final hasSaved = saved != null &&
        saved[2] >= _minSize.width &&
        saved[3] >= _minSize.height;

    final options = WindowOptions(
      size: hasSaved ? Size(saved[2], saved[3]) : _defaultSize,
      center: !hasSaved,
      minimumSize: _minSize,
      title: 'SyncPad',
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      if (hasSaved) {
        await windowManager.setBounds(
          Rect.fromLTWH(saved[0], saved[1], saved[2], saved[3]),
        );
      }
      await windowManager.show();
      await windowManager.focus();
    });

    windowManager.addListener(this);
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _saveNow);
  }

  Future<void> _saveNow() async {
    _debounce?.cancel();
    try {
      final b = await windowManager.getBounds();
      await _settings.setWindowFrame(b.left, b.top, b.width, b.height);
    } catch (_) {
      // 窗口正在销毁等情况，忽略。
    }
  }

  // 连续拖动/缩放：防抖保存，避免频繁写盘。
  @override
  void onWindowMove() => _scheduleSave();
  @override
  void onWindowResize() => _scheduleSave();

  // 手势结束：立即落盘（不触发结束事件的平台由防抖兜底）。
  @override
  void onWindowMoved() => _saveNow();
  @override
  void onWindowResized() => _saveNow();
}
