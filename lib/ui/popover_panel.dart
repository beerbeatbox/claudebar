import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/usage_forecast.dart';
import '../models/usage_error.dart';
import '../models/usage_snapshot.dart';
import '../state/usage_controller.dart';
import 'format.dart';
import 'meter_row.dart';
import 'plan_badge.dart';
import 'settings_panel.dart';
import 'tokens.dart';

/// The popover root — the translucent card with the up-arrow, switching
/// between the usage view, status states, and settings (design reference).
class Popover extends ConsumerStatefulWidget {
  final VoidCallback onQuit;

  /// Arrow-centre distance from the window's right edge, driven by the window
  /// positioner so the arrow tracks the status item.
  final ValueListenable<double> arrowFromRight;

  const Popover({
    super.key,
    required this.onQuit,
    required this.arrowFromRight,
  });

  @override
  ConsumerState<Popover> createState() => _PopoverState();
}

class _PopoverState extends ConsumerState<Popover> {
  bool _showSettings = false;

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    final state = ref.watch(usageControllerProvider);
    final forecast = ref.watch(forecastProvider);

    // No fill colour here on purpose: the side/bottom gutter must stay
    // hit-transparent so a tap there falls through to the dismiss layer behind
    // the popover. Only the card itself (the GestureDetector below) swallows
    // taps — clicking anywhere outside the card frame closes the popover.
    return Padding(
      // Side/bottom padding must outrun the shadow: the 36-blur shadow stays
      // visible for ~2 sigma (~42pt) past the card edge, plus the 18pt
      // downward offset at the bottom — anything tighter clips the fade into
      // a hard rectangle. Top is 0 so the arrow tip touches the window's top
      // edge, which the positioner pins right under the menu bar.
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 64),
      child: GestureDetector(
        // Opaque so the whole card frame swallows taps (keeping the popover
        // open), while the inner buttons still win their own taps. Empty.
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ValueListenableBuilder<double>(
          valueListenable: widget.arrowFromRight,
          builder:
              (context, fromRight, child) => CustomPaint(
                painter: _BubblePainter(
                  color: t.cardBg,
                  border: t.cardBorder,
                  // fromRight measures from the window edge; the painter works
                  // in card coordinates, inside the 40pt transparent gutter.
                  arrowCenterFromRight: fromRight - 40,
                ),
                child: child,
              ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, _kArrowHeight + 16, 18, 14),
            child:
                _showSettings
                    ? SettingsPanel(
                      onBack: () => setState(() => _showSettings = false),
                      onQuit: widget.onQuit,
                    )
                    : _UsageView(
                      state: state,
                      forecast: forecast,
                      onSettings: () => setState(() => _showSettings = true),
                    ),
          ),
        ),
      ),
    );
  }
}

class _UsageView extends StatelessWidget {
  final UsageState state;
  final Forecast? forecast;
  final VoidCallback onSettings;

  const _UsageView({
    required this.state,
    required this.forecast,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    final snapshot = state.snapshot;
    final error = state.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'ClaudeBar',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.13,
                color: t.text1,
              ),
            ),
            if (snapshot != null) PlanBadge(plan: snapshot.plan),
          ],
        ),
        const SizedBox(height: 14),

        // Body.
        if (snapshot == null && state.loading)
          _LoadingBody(t: t)
        else if (snapshot == null && error != null)
          _StatusBody(error: error, t: t)
        else if (snapshot != null) ...[
          if (snapshot.stale)
            _OfflineRow(
              t: t,
              message: '${error?.staleReason ?? 'Offline'} — showing last sync',
            ),
          MeterRow(
            window: snapshot.session,
            stale: snapshot.stale,
            fetchedAt: snapshot.fetchedAt,
          ),
          if (!snapshot.stale)
            _ForecastLine(
              forecast: forecast,
              resetsAt: snapshot.session.resetsAt,
              t: t,
            ),
          const SizedBox(height: 16),
          MeterRow(
            window: snapshot.weekly,
            colorize: false,
            stale: snapshot.stale,
            fetchedAt: snapshot.fetchedAt,
          ),
          if (snapshot.opus != null || snapshot.sonnet != null) ...[
            Divider(color: t.hairline, height: 28, thickness: 0.5),
            if (snapshot.opus != null) MiniMeterRow(window: snapshot.opus!),
            if (snapshot.sonnet != null) MiniMeterRow(window: snapshot.sonnet!),
          ],
        ],

        // Footer.
        Divider(color: t.hairline, height: 26, thickness: 0.5),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _footerStamp(snapshot, error),
              style: TextStyle(
                fontSize: 11,
                color: t.text3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            _FootBtn(icon: Icons.settings_outlined, onTap: onSettings, t: t),
          ],
        ),
      ],
    );
  }

  String _footerStamp(UsageSnapshot? snapshot, UsageError? error) {
    if (snapshot != null) return Fmt.updated(snapshot.fetchedAt);
    if (error != null) return 'Not synced';
    return '';
  }
}

/// The burn-rate line under the session meter. Always visible (when online) so
/// the feature never silently disappears — it just changes message:
///   • no/too-little history → "Burn rate · gathering data…"
///   • online but flat/idle  → "Burn rate · steady"
///   • climbing              → "🔥 ≈14%/hr · full by 15:20"
/// The ETA is dropped when the window won't fill before it resets — the rate
/// alone still tells the story.
class _ForecastLine extends StatelessWidget {
  final Forecast? forecast;
  final DateTime? resetsAt;
  final ClaudeTokens t;

  const _ForecastLine({
    required this.forecast,
    required this.resetsAt,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final f = forecast;

    final TextStyle base = TextStyle(
      fontSize: 11,
      color: t.text2,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget line(List<InlineSpan> spans, {TextStyle? style}) => Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Text.rich(TextSpan(children: spans), style: style ?? base),
    );

    // Not enough history yet to project from.
    if (f == null) {
      return line(
        const [TextSpan(text: '⏳ Burn rate · gathering data…')],
        style: base.copyWith(color: t.text3),
      );
    }

    // Online and idle — usage isn't climbing.
    if (!f.usable) {
      return line(const [TextSpan(text: '🔥 Burn rate · steady')]);
    }

    final full = f.full;
    final showEta =
        full != null && (resetsAt == null || full.isBefore(resetsAt!));

    return line([
      const TextSpan(text: '🔥 '),
      TextSpan(text: Fmt.ratePerHour(f.ratePerHour)),
      if (showEta) ...[
        TextSpan(text: ' · ', style: TextStyle(color: t.text3)),
        TextSpan(
          text: Fmt.fullBy(full),
          style: TextStyle(color: t.amber, fontWeight: FontWeight.w600),
        ),
      ],
    ]);
  }
}

class _OfflineRow extends StatelessWidget {
  final ClaudeTokens t;
  final String message;

  const _OfflineRow({required this.t, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: t.text3, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          Text(message, style: TextStyle(fontSize: 12, color: t.text2)),
        ],
      ),
    );
  }
}

class _StatusBody extends StatelessWidget {
  final UsageError error;
  final ClaudeTokens t;

  const _StatusBody({required this.error, required this.t});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: t.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                error.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: t.text1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            error.message,
            style: TextStyle(fontSize: 12, height: 1.45, color: t.text2),
          ),
        ],
      ),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  final ClaudeTokens t;
  const _LoadingBody({required this.t});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: t.text3),
          ),
          const SizedBox(width: 10),
          Text(
            'Reading usage…',
            style: TextStyle(fontSize: 12, color: t.text2),
          ),
        ],
      ),
    );
  }
}

class _FootBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final ClaudeTokens t;

  const _FootBtn({required this.icon, required this.onTap, required this.t});

  @override
  State<_FootBtn> createState() => _FootBtnState();
}

class _FootBtnState extends State<_FootBtn> {
  bool _pressed = false;
  bool _hover = false;

  /// Quick clicks fire tap-down and tap-up within a few ms — too fast for the
  /// pressed visual to register. Hold it on screen briefly before releasing.
  void _release() {
    Future.delayed(const Duration(milliseconds: 130), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final color = _hover ? t.text1 : t.text2;
    final bg =
        _pressed ? t.track : (_hover ? t.hairline : const Color(0x00000000));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => _release(),
        onTapCancel: _release,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 90),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: bg,
            ),
            child: Icon(widget.icon, size: 14, color: color),
          ),
        ),
      ),
    );
  }
}

/// Height of the up-pointing arrow above the card's top edge.
const double _kArrowHeight = 8;

/// Half-width of the arrow at its base.
const double _kArrowHalfWidth = 9;

/// Paints the card and its up-pointing arrow as one continuous path — single
/// fill, single hairline stroke, single shadow — so no seam can appear where
/// they meet. The arrow centre is [arrowCenterFromRight] from the card's
/// right edge, kept under the status item by the window positioner.
class _BubblePainter extends CustomPainter {
  final Color color;
  final Color border;
  final double arrowCenterFromRight;

  const _BubblePainter({
    required this.color,
    required this.border,
    required this.arrowCenterFromRight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = _bubblePath(size);

    // The card fill is translucent (native blur shows through it), so the
    // shadows must be clipped to OUTSIDE the bubble — drawn underneath they
    // would darken the glass instead of the desktop around it.
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTRB(-60, -60, size.width + 60, size.height + 80)),
        path,
      ),
    );
    canvas.drawPath(
      path.shift(const Offset(0, 18)),
      Paint()
        ..color = const Color(0x73000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, _sigma(36)),
    );
    canvas.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, _sigma(8)),
    );
    canvas.restore();

    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
  }

  Path _bubblePath(Size size) {
    const r = Radius.circular(14);
    const top = _kArrowHeight;
    final w = size.width;
    final h = size.height;
    final cx = w - arrowCenterFromRight;

    return Path()
      ..moveTo(14, top)
      ..lineTo(cx - _kArrowHalfWidth, top)
      // Slightly rounded tip instead of a sharp point.
      ..lineTo(cx - 1.5, 1.33)
      ..quadraticBezierTo(cx, 0, cx + 1.5, 1.33)
      ..lineTo(cx + _kArrowHalfWidth, top)
      ..lineTo(w - 14, top)
      ..arcToPoint(Offset(w, top + 14), radius: r)
      ..lineTo(w, h - 14)
      ..arcToPoint(Offset(w - 14, h), radius: r)
      ..lineTo(14, h)
      ..arcToPoint(Offset(0, h - 14), radius: r)
      ..lineTo(0, top + 14)
      ..arcToPoint(const Offset(14, top), radius: r)
      ..close();
  }

  /// Matches BoxShadow's blur-radius-to-sigma conversion so the shadow looks
  /// identical to the previous DecoratedBox version.
  static double _sigma(double blurRadius) => blurRadius * 0.57735 + 0.5;

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.color != color ||
      old.border != border ||
      old.arrowCenterFromRight != arrowCenterFromRight;
}
