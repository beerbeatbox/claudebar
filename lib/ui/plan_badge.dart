import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// The plan chip in the popover header, e.g. "MAX" (design reference .badge).
class PlanBadge extends StatelessWidget {
  final String plan;
  const PlanBadge({super.key, required this.plan});

  @override
  Widget build(BuildContext context) {
    final t = ClaudeTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: t.hairline, width: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        plan.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: t.text2,
        ),
      ),
    );
  }
}
