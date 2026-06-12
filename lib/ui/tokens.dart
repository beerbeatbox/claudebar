import 'package:flutter/widgets.dart';

/// Threshold percentages shared across the menu-bar glyph and the popover
/// meters (design reference §tokens).
const double kWarnThreshold = 75;
const double kCritThreshold = 90;

/// Resolves a 0–100 percentage to its threshold color using [ClaudeTokens].
Color levelColor(double percent, ClaudeTokens t) {
  if (percent >= kCritThreshold) return t.red;
  if (percent >= kWarnThreshold) return t.amber;
  return t.accent;
}

/// Design tokens for ClaudeBar, mirroring the light/dark palettes in
/// `claudebar-design-reference.html`. Pulled from context via [of].
class ClaudeTokens {
  final Color cardBg;
  final Color cardBorder;
  final Color text1;
  final Color text2;
  final Color text3;
  final Color track;
  final Color hairline;
  final Color accent;
  final Color amber;
  final Color red;

  const ClaudeTokens({
    required this.cardBg,
    required this.cardBorder,
    required this.text1,
    required this.text2,
    required this.text3,
    required this.track,
    required this.hairline,
    required this.accent,
    required this.amber,
    required this.red,
  });

  // cardBg is fully transparent: the card surface IS the native
  // NSVisualEffectView glass behind the window — any fill here only
  // muddies it.
  static const ClaudeTokens dark = ClaudeTokens(
    cardBg: Color(0x001E1E23),
    cardBorder: Color(0x1FFFFFFF),
    text1: Color(0xF2FFFFFF),
    text2: Color(0x8FFFFFFF),
    text3: Color(0x57FFFFFF),
    track: Color(0x24FFFFFF),
    hairline: Color(0x1AFFFFFF),
    accent: Color(0xFFE68A5C),
    amber: Color(0xFFF0B43C),
    red: Color(0xFFF2645F),
  );

  static const ClaudeTokens light = ClaudeTokens(
    cardBg: Color(0x00F7F7F9),
    cardBorder: Color(0x14000000),
    text1: Color(0xE0000000),
    text2: Color(0x80000000),
    text3: Color(0x57000000),
    track: Color(0x1A000000),
    hairline: Color(0x14000000),
    accent: Color(0xFFC45B36),
    amber: Color(0xFFB6790E),
    red: Color(0xFFCE3A40),
  );

  static ClaudeTokens of(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    return brightness == Brightness.dark ? dark : light;
  }
}
