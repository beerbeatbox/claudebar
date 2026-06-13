// Unit tests for UsageError's user-facing labels — in particular that a
// kept-but-stale snapshot names its *actual* cause instead of always claiming
// "Offline" (the old bug: a flaky empty CLI reply read as a network outage).

import 'package:claude_usage_bar/models/usage_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsageError.staleReason', () {
    test('only a real network failure reads as "Offline"', () {
      expect(UsageError.network.staleReason, 'Offline');
    });

    test('an empty CLI reply is "No fresh reading", not "Offline"', () {
      expect(UsageError.noData.staleReason, 'No fresh reading');
      expect(UsageError.noData.staleReason, isNot('Offline'));
    });

    test('a format change is "Couldn’t read usage", not "Offline"', () {
      expect(UsageError.parseFailed.staleReason, 'Couldn’t read usage');
      expect(UsageError.parseFailed.staleReason, isNot('Offline'));
    });

    test('noData is its own kind, distinct from parseFailed', () {
      expect(UsageError.noData.kind, UsageErrorKind.noData);
      expect(UsageError.noData.kind, isNot(UsageErrorKind.parseFailed));
    });
  });
}
