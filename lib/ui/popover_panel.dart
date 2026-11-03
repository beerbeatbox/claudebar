import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/usage_error.dart';
import '../models/usage_snapshot.dart';
import '../state/sign_in_controller.dart';
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
    final signingIn = ref.watch(
      signInControllerProvider.select((s) => s.inProgress),
    );

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
                      signingIn: signingIn,
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

  /// A ClaudeBar-started sign-in is running (see [SignInController]).
  final bool signingIn;
  final VoidCallback onSettings;

  const _UsageView({
    required this.state,
    required this.signingIn,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    final snapshot = state.snapshot;
    final error = state.error;
    // Signed out — or signing in right now: the one actionable state, so it
    // leads the card and never gets swapped for "Reading usage…" by a
    // background retry (that would whisk away the Cancel button mid-sign-in).
    final showSignIn = state.needsSignIn || signingIn;

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
        if (showSignIn) ...[
          _SignInBlock(error: error, t: t),
          // Room before the greyed meters the card explains; alone, the
          // footer divider already spaces it.
          if (snapshot != null) const SizedBox(height: 12),
        ],
        if (snapshot == null && !showSignIn && state.loading)
          _LoadingBody(t: t)
        else if (snapshot == null && !showSignIn && error != null)
          _StatusBody(title: error.title, message: error.message, t: t)
        else if (snapshot != null) ...[
          // The sign-in block above already says why the meters are grey.
          // (After a sign-in the error is cleared while the next probe runs;
          // the stale meters then sit for that second without a banner.)
          if (snapshot.stale && error != null && !showSignIn)
            _OfflineRow(
              t: t,
              message: '${error.staleReason} — showing last sync',
            ),
          MeterRow(
            window: snapshot.session,
            stale: snapshot.stale,
            fetchedAt: snapshot.fetchedAt,
          ),
          const SizedBox(height: 16),
          MeterRow(
            window: snapshot.weekly,
            colorize: false,
            stale: snapshot.stale,
            fetchedAt: snapshot.fetchedAt,
          ),
          if (snapshot.models.isNotEmpty) ...[
            Divider(color: t.hairline, height: 28, thickness: 0.5),
            for (final window in snapshot.models) MiniMeterRow(window: window),
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

/// A status card: amber dot (or [leading]) + heading, a body line, and an
/// optional row of [actions].
class _StatusBody extends StatelessWidget {
  final String title;
  final String message;
  final ClaudeTokens t;

  /// Replaces the amber dot, e.g. with a spinner while waiting.
  final Widget? leading;
  final List<Widget> actions;

  const _StatusBody({
    required this.title,
    required this.message,
    required this.t,
    this.leading,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: Center(
                  child: leading ??
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: t.amber,
                          shape: BoxShape.circle,
                        ),
                      ),
                ),
              ),
              // 10 + 7 keeps the heading where the old 8pt dot + 9 put it.
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.text1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: TextStyle(fontSize: 12, height: 1.45, color: t.text2),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: actions),
          ],
        ],
      ),
    );
  }
}

/// The signed-out card: what happened and a one-click way back — "Sign in…"
/// runs the CLI's browser sign-in headless, "Use Terminal" the same sign-in
/// in a Terminal window — then, while one runs, what to finish and a Cancel.
/// Either way usage refreshes by itself the moment the sign-in lands.
class _SignInBlock extends ConsumerWidget {
  /// The usage error that brought the card up; null in the moment between a
  /// sign-in starting and the next probe.
  final UsageError? error;
  final ClaudeTokens t;

  const _SignInBlock({required this.error, required this.t});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signIn = ref.watch(signInControllerProvider);
    final controller = ref.read(signInControllerProvider.notifier);

    final Widget body;
    if (signIn.inProgress) {
      final inTerminal = signIn.phase == SignInPhase.terminal;
      body = _StatusBody(
        t: t,
        leading: SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: t.text3),
        ),
        title: 'Waiting for sign-in…',
        message: inTerminal
            ? 'A Terminal window is open — finish signing in there, and '
                'ClaudeBar refreshes on its own.'
            // The headless flow can't take a pasted code (the page offers one
            // only if its hand-back to the CLI fails), so point at the route
            // that can — one tap away below.
            : 'Your browser should be open — finish signing in there, and '
                'ClaudeBar refreshes on its own. Asked to paste a code? Use '
                'Terminal instead.',
        actions: [
          _ActionBtn(label: 'Cancel', onTap: controller.cancel, t: t),
          if (!inTerminal)
            _ActionBtn(
              label: 'Use Terminal',
              onTap: () => controller.signIn(terminal: true),
              t: t,
            ),
        ],
      );
    } else {
      final failure = signIn.error;
      final shown = error ?? UsageError.noCredentials;
      body = _StatusBody(
        t: t,
        title: shown.title,
        message: failure ?? shown.message,
        actions: [
          _ActionBtn(
            label: failure == null ? 'Sign in…' : 'Try again',
            primary: true,
            onTap: controller.signIn,
            t: t,
          ),
          _ActionBtn(
            label: 'Use Terminal',
            onTap: () => controller.signIn(terminal: true),
            t: t,
          ),
        ],
      );
    }
    return body;
  }
}

/// A compact text button for a status card's actions: accent-tinted for the
/// primary one, plain for the rest (same hover/press feel as [_FootBtn]).
class _ActionBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final ClaudeTokens t;

  const _ActionBtn({
    required this.label,
    required this.onTap,
    required this.t,
    this.primary = false,
  });

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final Color fg;
    final Color bg;
    if (widget.primary) {
      fg = t.accent;
      bg = t.accent.withValues(alpha: _pressed ? 0.30 : (_hover ? 0.22 : 0.15));
    } else {
      fg = _hover ? t.text1 : t.text2;
      bg = _pressed ? t.track : (_hover ? t.hairline : const Color(0x00000000));
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: widget.primary ? FontWeight.w600 : FontWeight.w500,
              color: fg,
            ),
          ),
        ),
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
