import 'package:flutter/widgets.dart';

import '../models/usage_window.dart';
import 'format.dart';
import 'tokens.dart';

/// A primary meter row: label, big tabular % number, a thin animated bar, and
/// a reset countdown (design reference .meter, spec §9).
class MeterRow extends StatelessWidget {
  final UsageWindow window;

  /// When false (e.g. weekly while session is the headline, or stale data),
  /// the number stays neutral instead of taking the threshold color.
  final bool colorize;

  /// Forces the neutral/stale tertiary color for offline display.
  final bool stale;

  /// When the stale snapshot was fetched — shown as "As of HH:mm".
  final DateTime? fetchedAt;

  const MeterRow({
    super.key,
    required this.window,
    this.colorize = true,
    this.stale = false,
    this.fetchedAt,
  });

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    final Color meter =
        stale ? t.text3 : (colorize ? levelColor(window.percent, t) : t.accent);
    final reset = stale
        ? (fetchedAt != null ? Fmt.asOf(fetchedAt!) : null)
        : Fmt.resets(window.resetsAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          window.label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.77,
            color: t.text2,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          Fmt.pct(window.percent),
          style: TextStyle(
            fontSize: 34,
            height: 1.05,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.6,
            color: stale ? t.text3 : meter,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 8),
        _Bar(percent: window.percent, color: meter, track: t.track),
        if (reset != null) ...[
          const SizedBox(height: 7),
          Text(reset, style: TextStyle(fontSize: 11, color: t.text3)),
        ],
      ],
    );
  }
}

/// A thin per-model row: label, mini bar, right-aligned % (design .mini).
class MiniMeterRow extends StatelessWidget {
  final UsageWindow window;
  const MiniMeterRow({super.key, required this.window});

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              window.label,
              style: TextStyle(fontSize: 11, color: t.text2, letterSpacing: 0.2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _Bar(percent: window.percent, color: t.accent, track: t.track, height: 4),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 34,
            child: Text(
              Fmt.pct(window.percent),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                color: t.text1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final double percent;
  final Color color;
  final Color track;
  final double height;

  const _Bar({
    required this.percent,
    required this.color,
    required this.track,
    this.height = 6,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Stack(
        children: [
          Container(height: height, color: track),
          LayoutBuilder(
            builder: (context, c) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                height: height,
                width: c.maxWidth * (percent.clamp(0, 100) / 100),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(999),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
