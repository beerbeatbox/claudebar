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

  // Both palettes use a near-opaque card fill (~93%). A fully transparent fill
  // let the native NSVisualEffectView take on whatever sat behind the window —
  // a dark desktop crushed the light card to mid-grey, a bright one washed the
  // dark card out — wrecking text contrast either way. A firm surface keeps the
  // card legible on ANY background; secondary/tertiary inks and hairlines are
  // also strengthened to clear WCAG AA.
  static const ClaudeTokens dark = ClaudeTokens(
    cardBg: Color(0xED1E1E23),
    cardBorder: Color(0x33FFFFFF),
    text1: Color(0xF2FFFFFF),
    text2: Color(0xA6FFFFFF),
    text3: Color(0x8CFFFFFF),
    track: Color(0x33FFFFFF),
    hairline: Color(0x2EFFFFFF),
    accent: Color(0xFFE68A5C),
    amber: Color(0xFFF0B43C),
    red: Color(0xFFF2645F),
  );

  // Near-opaque (~93%) for the same reason as dark (see above): a firm light
  // surface keeps black ink readable on any background, instead of letting a
  // dark desktop pull the card down to a muddy mid-grey.
  static const ClaudeTokens light = ClaudeTokens(
    cardBg: Color(0xEDF7F7F9),
    cardBorder: Color(0x26000000),
    text1: Color(0xF2000000),
    text2: Color(0xA6000000),
    text3: Color(0x8C000000),
    track: Color(0x2E000000),
    hairline: Color(0x24000000),
    accent: Color(0xFFB84E2A),
    amber: Color(0xFF9C6A0C),
    red: Color(0xFFC42A30),
  );

  static ClaudeTokens of(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    return brightness == Brightness.dark ? dark : light;
  }
}
