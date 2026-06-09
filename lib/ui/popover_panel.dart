import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  const Popover({super.key, required this.onQuit});

  @override
  ConsumerState<Popover> createState() => _PopoverState();
}

class _PopoverState extends ConsumerState<Popover> {
  bool _showSettings = false;

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    final state = ref.watch(usageControllerProvider);

    return Container(
      color: const Color(0x00000000),
      // Generous padding so the card's drop-shadow can fade over the now
      // transparent window instead of being clipped to a hard edge.
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Arrow(color: t.cardBg, border: t.cardBorder),
          DecoratedBox(
            decoration: BoxDecoration(
              color: t.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.cardBorder, width: 0.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x73000000),
                  blurRadius: 36,
                  offset: Offset(0, 18),
                ),
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
              child:
                  _showSettings
                      ? SettingsPanel(
                        onBack: () => setState(() => _showSettings = false),
                        onQuit: widget.onQuit,
                      )
                      : _UsageView(
                        state: state,
                        onRefresh:
                            () =>
                                ref
                                    .read(usageControllerProvider.notifier)
                                    .refresh(),
                        onSettings: () => setState(() => _showSettings = true),
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageView extends StatelessWidget {
  final UsageState state;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  const _UsageView({
    required this.state,
    required this.onRefresh,
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
          if (snapshot.stale) _OfflineRow(t: t),
          MeterRow(window: snapshot.session, stale: snapshot.stale),
          const SizedBox(height: 16),
          MeterRow(
            window: snapshot.weekly,
            colorize: false,
            stale: snapshot.stale,
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
            Row(
              children: [
                _FootBtn(
                  icon: Icons.refresh,
                  label: 'Refresh',
                  onTap: onRefresh,
                  t: t,
                  busy: state.loading,
                ),
                const SizedBox(width: 4),
                _FootBtn(
                  icon: Icons.settings_outlined,
                  onTap: onSettings,
                  t: t,
                ),
              ],
            ),
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
  const _OfflineRow({required this.t});

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
          Text(
            'Offline — showing last sync',
            style: TextStyle(fontSize: 12, color: t.text2),
          ),
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

class _FootBtn extends StatelessWidget {
  final IconData icon;
  final String? label;
  final VoidCallback onTap;
  final ClaudeTokens t;
  final bool busy;

  const _FootBtn({
    required this.icon,
    this.label,
    required this.onTap,
    required this.t,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
        child: Row(
          children: [
            Icon(icon, size: 14, color: t.text2),
            if (label != null) ...[
              const SizedBox(width: 5),
              Text(label!, style: TextStyle(fontSize: 12, color: t.text2)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The little up-pointing arrow above the card, near the right where macOS
/// menu-bar items live.
class _Arrow extends StatelessWidget {
  final Color color;
  final Color border;
  const _Arrow({required this.color, required this.border});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 24),
        child: Transform.translate(
          // Pull the arrow down so its flat edge tucks behind the card seam.
          // (A negative Container margin would trip Flutter's isNonNegative assert.)
          offset: const Offset(0, 6),
          child: Transform.rotate(
            angle: 0.785398, // 45°
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
                border: Border(
                  top: BorderSide(color: border, width: 0.5),
                  left: BorderSide(color: border, width: 0.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
