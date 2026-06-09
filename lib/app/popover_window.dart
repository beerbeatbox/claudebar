import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Owns the single frameless window and drives it as a menu-bar popover:
/// position it under the status item, show/focus it, and hide it on blur
/// (spec §6, §10 Phase 2).
class PopoverWindow with WindowListener {
  // 300pt card + 22pt transparent padding on each side (room for the shadow).
  static const double width = 344;
  double _height = 360;

  bool _ready = false;

  /// Configures the window as a hidden, frameless, transparent, always-on-top
  /// popover. Call once at startup before the first show.
  Future<void> init() async {
    windowManager.addListener(this);

    const options = WindowOptions(
      size: Size(width, 360),
      center: false,
      backgroundColor: Color(0x00000000),
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.setBackgroundColor(const Color(0x00000000));
      await windowManager.setHasShadow(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setResizable(false);
      await windowManager.setMovable(false);
      await windowManager.setVisibleOnAllWorkspaces(true);
      await windowManager.hide();
    });

    _ready = true;
  }

  /// Resizes the window to fit measured content height (width is fixed).
  Future<void> setContentHeight(double height) async {
    final h = height.ceilToDouble();
    if ((h - _height).abs() < 1) return;
    _height = h;
    if (_ready) {
      await windowManager.setSize(Size(width, h));
      // Re-pin position so the arrow stays anchored when height changes.
      if (await windowManager.isVisible()) await _position();
    }
  }

  Future<void> toggle() async {
    if (await windowManager.isVisible()) {
      await windowManager.hide();
    } else {
      await show();
    }
  }

  Future<void> show() async {
    await _position();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hide() => windowManager.hide();

  /// Places the window so its up-arrow (≈37pt from the right edge) sits under
  /// the cursor, clamped to the primary display's visible frame.
  Future<void> _position() async {
    final cursor = await screenRetriever.getCursorScreenPoint();
    final display = await screenRetriever.getPrimaryDisplay();

    final visPos = display.visiblePosition ?? Offset.zero;
    final visSize = display.visibleSize ?? display.size;

    // Arrow centre = right padding (22) + Align right inset (24) + half-arrow (6).
    const arrowFromRight = 52.0;
    double left = cursor.dx - (width - arrowFromRight);
    final minLeft = visPos.dx + 4;
    final maxLeft = visPos.dx + visSize.width - width - 4;
    left = left.clamp(minLeft, math.max(minLeft, maxLeft));

    final top = visPos.dy; // just below the menu bar
    await windowManager.setPosition(Offset(left, top));
  }

  @override
  void onWindowBlur() {
    windowManager.hide();
  }
}
