// Tripwire for native invariants that `flutter test` cannot exercise:
// widget tests inject pointer events directly into the Flutter framework, so
// they all pass even when AppKit routes real clicks somewhere else (which is
// exactly how the dead-settings-gear bug shipped). The real regression test
// lives in macos/RunnerTests/RunnerTests.swift and needs a Mac; this one at
// least fails fast — on any platform — if the load-bearing hitTest override
// is dropped in a refactor.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PopoverBlurView keeps its hitTest-nil override', () {
    final src =
        File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();

    final start = src.indexOf('class PopoverBlurView');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'PopoverBlurView moved or was renamed — move this guard (and '
            'macos/RunnerTests) along with it.');
    final end = src.indexOf('class MainFlutterWindow');
    final body = src.substring(start, end > start ? end : src.length);

    final overridesHitTest = RegExp(
      r'override\s+func\s+hitTest\s*\([^)]*\)\s*->\s*NSView\?\s*\{\s*(return\s+)?nil\s*\}',
    ).hasMatch(body);

    expect(overridesHitTest, isTrue,
        reason: 'PopoverBlurView must override hitTest to return nil. '
            'Without it the backdrop can win AppKit hit-testing over the '
            'FlutterView and silently swallow every click in the popover '
            '(hover keeps working — tracking areas bypass hitTest), which is '
            'the v1.1.0 dead-settings-gear bug.');
  });
}
