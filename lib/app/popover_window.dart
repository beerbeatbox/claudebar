import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Owns the single frameless window and drives it as a menu-bar popover:
/// position it under the status item, show/focus it, and hide it on blur
/// (spec §6, §10 Phase 2).
class PopoverWindow with WindowListener {
  // 300pt card + 40pt transparent padding on each side, sized so the 36pt
  // shadow blur fades to nothing before reaching the window edge (a smaller
  // gutter clips the blur into a visible hard rectangle).
  static const double width = 380;

  /// Where the arrow sits when nothing forces the window off-anchor:
  /// right padding (40) + 30pt into the card.
  static const double _preferredArrowFromRight = 70;

  /// Keeps the arrow base on the card's flat top edge: 40pt window padding +
  /// 14pt corner radius + 9pt arrow half-width, plus a hair of slack.
  static const double _minArrowFromRight = 64;

  double _height = 360;
  bool _ready = false;

  /// X of the point the arrow points at — the status item's centre — cached
  /// while visible so height changes never re-anchor to the (moved) cursor.
  double? _anchorX;

  /// Arrow distance from the window's right edge. The panel listens to this
  /// so the arrow stays on the icon even when the window clamps at a screen
  /// edge.
  final ValueNotifier<double> arrowFromRight =
      ValueNotifier(_preferredArrowFromRight);

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
      // Re-pin so the card stays under the menu bar after the resize; the
      // cached anchor keeps the horizontal position rock-steady.
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
    _anchorX = await _resolveAnchorX();
    await _position();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hide() => windowManager.hide();

  /// The status item's horizontal centre, falling back to the cursor (the
  /// click that opened us) when the tray bounds are unavailable.
  Future<double> _resolveAnchorX() async {
    try {
      final bounds = await trayManager.getBounds();
      if (bounds != null && bounds.width > 0) return bounds.center.dx;
    } catch (_) {}
    return (await screenRetriever.getCursorScreenPoint()).dx;
  }

  /// Places the window so its up-arrow sits under the status item, clamped to
  /// the anchor display's visible frame; the arrow inset absorbs any clamping.
  Future<void> _position() async {
    final anchorX = _anchorX ??= await _resolveAnchorX();
    final display = await _displayContaining(anchorX);

    final visPos = display.visiblePosition ?? Offset.zero;
    final visSize = display.visibleSize ?? display.size;

    double left = anchorX - (width - _preferredArrowFromRight);
    final minLeft = visPos.dx + 4;
    final maxLeft = visPos.dx + visSize.width - width - 4;
    left = left.clamp(minLeft, math.max(minLeft, maxLeft));

    arrowFromRight.value = (width - (anchorX - left)).clamp(
      _minArrowFromRight,
      width - _minArrowFromRight,
    );

    final top = visPos.dy; // just below the menu bar
    await windowManager.setPosition(Offset(left, top));
  }

  /// The display whose visible frame contains [x] (the status item can live
  /// on any screen), defaulting to the primary display.
  Future<Display> _displayContaining(double x) async {
    final displays = await screenRetriever.getAllDisplays();
    for (final d in displays) {
      final pos = d.visiblePosition;
      final size = d.visibleSize ?? d.size;
      if (pos != null && x >= pos.dx && x < pos.dx + size.width) return d;
    }
    return screenRetriever.getPrimaryDisplay();
  }

  @override
  void onWindowBlur() {
    windowManager.hide();
  }
}
