import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Renders the menu-bar status glyph to PNG bytes — a small ring gauge whose
/// arc tracks the selected usage window, matching variant G ("Ring +
/// countdown") in claudebarbarmockups.html.
///
/// tray_manager's Dart `setIcon` only loads bundled assets, so the glyph is
/// drawn at runtime and handed to the native side as base64 (see TrayController).
Future<Uint8List> renderTrayGlyph({
  required double percent,
  required Color color,
  required Color track,
  double scale = 3,
}) async {
  // Logical 18×18pt icon; the ring is 16pt across including its stroke
  // (r=6 + 2.6pt stroke), centered — same proportions as the mockup's SVG.
  const double box = 18;
  const double radius = 6;
  const double stroke = 2.6;
  const center = Offset(box / 2, box / 2);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);

  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track,
  );

  final sweep = 2 * math.pi * (percent.clamp(0, 100) / 100);
  if (sweep > 0.01) {
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2, // start at 12 o'clock, like the mockup's rotate(-90)
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  final picture = recorder.endRecording();
  final side = (box * scale).round();
  final image = await picture.toImage(side, side);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
