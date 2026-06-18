import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/prefs.dart';
import 'tokens.dart';

/// Settings view inside the popover: menu-bar metric, refresh interval,
/// launch-at-login, and quit (spec §10, Phase 2).
class SettingsPanel extends ConsumerWidget {
  final VoidCallback onBack;
  final VoidCallback onQuit;

  const SettingsPanel({super.key, required this.onBack, required this.onQuit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ClaudeTokens.of(context);
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _IconBtn(icon: Icons.chevron_left, onTap: onBack, color: t.text2),
            const SizedBox(width: 4),
            Text(
              'Settings',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.text1),
            ),
          ],
        ),
        const SizedBox(height: 16),

        _Label('Menu-bar shows', t),
        const SizedBox(height: 8),
        _Segmented<MenuBarMetric>(
          value: settings.metric,
          options: const {
            MenuBarMetric.session: 'Session',
            MenuBarMetric.weekly: 'Weekly',
          },
          onChanged: controller.setMetric,
        ),
        const SizedBox(height: 18),

        _Label('Refresh every', t),
        const SizedBox(height: 8),
        _Segmented<int>(
          value: settings.refreshMinutes,
          options: const {2: '2m', 5: '5m', 15: '15m'},
          onChanged: controller.setRefreshMinutes,
        ),
        const SizedBox(height: 18),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Label('Open at login', t),
            Switch.adaptive(
              value: settings.launchAtLogin,
              activeTrackColor: t.accent,
              onChanged: (v) => controller.setLaunchAtLogin(v),
            ),
          ],
        ),
        const SizedBox(height: 14),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Label('Receive beta updates', t),
            Switch.adaptive(
              value: settings.betaUpdates,
              activeTrackColor: t.accent,
              onChanged: (v) => controller.setBetaUpdates(v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Get pre-release builds early to help test fixes. '
          'Stable releases still arrive on this channel.',
          style: TextStyle(fontSize: 10.5, height: 1.3, color: t.text3),
        ),
        const SizedBox(height: 8),
        Divider(color: t.hairline, height: 24, thickness: 0.5),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: onQuit,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              foregroundColor: t.text2,
            ),
            child: const Text('Quit ClaudeBar', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  final ClaudeTokens t;
  const _Label(this.text, this.t);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: t.text2,
      ),
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  const _Segmented({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: t.track,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: options.entries.map((e) {
          final selected = e.key == value;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(e.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(
                  color: selected ? t.cardBg : const Color(0x00000000),
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: selected
                      ? const [BoxShadow(color: Color(0x26000000), blurRadius: 2, offset: Offset(0, 1))]
                      : null,
                ),
                child: Text(
                  e.value,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: selected ? t.text1 : t.text2,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  const _IconBtn({required this.icon, required this.onTap, required this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Icon(icon, size: 20, color: color),
    );
  }
}
