import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Renders the menu-bar status glyph to PNG bytes — a two-bar meter where the
/// thick top bar tracks the 5-hour session and the bottom hairline tracks the
/// week, matching the `.glyph` spec in claudebar-design-reference.html.
///
/// tray_manager's Dart `setIcon` only loads bundled assets, so the glyph is
/// drawn at runtime and handed to the native side as base64 (see TrayController).
Future<Uint8List> renderTrayGlyph({
  required double sessionPercent,
  required double weeklyPercent,
  required Color sessionColor,
  required Color weeklyColor,
  required Color track,
  double scale = 3,
}) async {
  // Logical 18×18pt icon; the glyph is 17pt wide / 10pt tall, centered.
  const double box = 18;
  const double glyphW = 17;
  const double topH = 5, gap = 3, botH = 2;
  const double glyphH = topH + gap + botH; // 10
  final double left = (box - glyphW) / 2;
  final double top = (box - glyphH) / 2;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);

  void bar(double y, double h, double pct, Color fill) {
    final radius = Radius.circular(h < 4 ? h / 2 : 2);
    final trackRect = RRect.fromLTRBR(left, y, left + glyphW, y + h, radius);
    canvas.drawRRect(trackRect, Paint()..color = track);
    final w = glyphW * (pct.clamp(0, 100) / 100);
    if (w > 0.5) {
      final fillRect = RRect.fromLTRBR(left, y, left + w, y + h, radius);
      canvas.drawRRect(fillRect, Paint()..color = fill);
    }
  }

  bar(top, topH, sessionPercent, sessionColor);
  bar(top + topH + gap, botH, weeklyPercent, weeklyColor);

  final picture = recorder.endRecording();
  final side = (box * scale).round();
  final image = await picture.toImage(side, side);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
