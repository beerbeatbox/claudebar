import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cli_usage_source.dart';
import '../data/credentials_reader.dart';
import '../data/usage_api.dart';
import '../models/usage_error.dart';
import '../models/usage_snapshot.dart';
import '../models/usage_window.dart';
import '../settings/prefs.dart';

/// Serves canned usage data instead of reading the real Keychain. Off by
/// default; pass `--dart-define=CLAUDEBAR_FAKE_USAGE=true` for UI work where
/// the macOS Keychain password prompt on every re-signed debug build gets in
/// the way.
const bool kFakeUsage = bool.fromEnvironment('CLAUDEBAR_FAKE_USAGE');

/// The single source of truth for usage data, listened to by both the tray
/// controller and the popover UI (spec §4).
class UsageState {
  final UsageSnapshot? snapshot;
  final UsageError? error;
  final bool loading;

  /// Until this instant, refresh requests are ignored and the Refresh button
  /// is disabled — either the post-refresh cooldown or a 429 backoff window.
  final DateTime? lockedUntil;

  const UsageState({
    this.snapshot,
    this.error,
    this.loading = false,
    this.lockedUntil,
  });

  const UsageState.loading()
    : snapshot = null,
      error = null,
      loading = true,
      lockedUntil = null;

  bool get locked =>
      lockedUntil != null && DateTime.now().isBefore(lockedUntil!);

  UsageState copyWith({
    UsageSnapshot? snapshot,
    UsageError? error,
    bool? loading,
    DateTime? lockedUntil,
    bool clearError = false,
    bool clearLock = false,
  }) {
    return UsageState(
      snapshot: snapshot ?? this.snapshot,
      error: clearError ? null : (error ?? this.error),
      loading: loading ?? this.loading,
      lockedUntil: clearLock ? null : (lockedUntil ?? this.lockedUntil),
    );
  }
}

final credentialsReaderProvider = Provider<CredentialsReader>(
  (ref) => CredentialsReader(),
);

final cliUsageSourceProvider = Provider<CliUsageSource>(
  (ref) => CliUsageSource(),
);

final usageApiProvider = Provider<UsageApi>((ref) => UsageApi());

class UsageController extends Notifier<UsageState> {
  /// Minimum gap between refreshes once one succeeds — usage data doesn't
  /// move faster than this, and the endpoint's quota has proven tight enough
  /// that even a single extra request minutes after the last one can 429.
  static const _cooldown = Duration(seconds: 60);

  /// 429 backoff ladder: 1 → 2 → 4 → 8 minutes, capped.
  static const _maxBackoff = Duration(minutes: 8);

  Timer? _timer;
  Timer? _unlockTimer;
  bool _refreshing = false;
  Duration _backoff = Duration.zero;

  @override
  UsageState build() {
    final minutes = ref.watch(settingsProvider.select((s) => s.refreshMinutes));

    ref.onDispose(() {
      _timer?.cancel();
      _unlockTimer?.cancel();
    });
    _timer?.cancel();
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => refresh());

    // Changing the interval re-runs build (it watches refreshMinutes). Keep
    // the current snapshot and cooldown lock — resetting to loading() blanked
    // the menu-bar title to "–" and re-fetched outside the cooldown on every
    // settings tweak. The new timer cadence takes over from here.
    final previous = stateOrNull;
    if (previous != null) return previous;

    // Kick off the first load after the notifier is constructed.
    Future.microtask(refresh);

    return const UsageState.loading();
  }

  /// Reads credentials, fetches usage, and updates state. On network failure
  /// the last snapshot is kept and marked stale (spec §11).
  ///
  /// The app, not the caller, owns the request rate: calls are dropped while
  /// a fetch is in flight, during the post-success cooldown, and during a 429
  /// backoff window — so neither button-mashing nor the periodic timer can
  /// hammer the endpoint.
  Future<void> refresh() async {
    if (_refreshing || state.locked) return;
    _refreshing = true;
    try {
      await _refresh();
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refresh() async {
    state = state.copyWith(loading: true);

    if (kFakeUsage) {
      state = UsageState(snapshot: _fakeSnapshot(), loading: false);
      _lock(_cooldown);
      return;
    }

    // CLI-first: `claude -p "/usage"` reads credentials inside Claude Code's
    // own process, so it can never trip the macOS Keychain password prompt —
    // the item's ACL only gates *other* apps, and on some machines Claude
    // Code wipes that ACL on every token rotation, which made "Always Allow"
    // not stick. Falls back to the Keychain + API path below when the CLI is
    // missing, logged out, or its output changes shape.
    final cliSnapshot = await ref.read(cliUsageSourceProvider).fetch();
    if (cliSnapshot != null) {
      _backoff = Duration.zero;
      state = UsageState(snapshot: cliSnapshot, loading: false);
      _lock(_cooldown);
      return;
    }

    final reader = ref.read(credentialsReaderProvider);
    var credResult = await reader.read();
    if (!credResult.isOk) {
      state = UsageState(
        snapshot: _stale(),
        error: credResult.error,
        loading: false,
      );
      return;
    }

    var usageResult = await ref
        .read(usageApiProvider)
        .fetch(credResult.credentials!);

    // A 401 usually means the cached token was rotated by Claude Code while
    // we held it — drop the cache, re-read the file/Keychain, and retry once.
    // If the store still has the same dead token, the second 401 surfaces as
    // the normal expired-token state.
    if (usageResult.error?.kind == UsageErrorKind.expiredToken) {
      reader.invalidate();
      credResult = await reader.read();
      if (credResult.isOk) {
        usageResult =
            await ref.read(usageApiProvider).fetch(credResult.credentials!);
      }
    }
    if (usageResult.isOk) {
      _backoff = Duration.zero;
      state = UsageState(snapshot: usageResult.snapshot, loading: false);
      _lock(_cooldown);
    } else if (usageResult.error?.kind == UsageErrorKind.rateLimited) {
      _backoff =
          _backoff == Duration.zero
              ? const Duration(minutes: 1)
              : (_backoff * 2 > _maxBackoff ? _maxBackoff : _backoff * 2);
      state = UsageState(
        snapshot: _stale(),
        error: usageResult.error,
        loading: false,
      );
      _lock(_backoff, retryAfter: true);
    } else {
      state = UsageState(
        snapshot: _stale(),
        error: usageResult.error,
        loading: false,
      );
    }
  }

  /// Blocks refreshes for [duration] and schedules the unlock, optionally
  /// retrying automatically once the window passes (the 429 path).
  void _lock(Duration duration, {bool retryAfter = false}) {
    _unlockTimer?.cancel();
    state = state.copyWith(lockedUntil: DateTime.now().add(duration));
    _unlockTimer = Timer(duration, () {
      state = state.copyWith(clearLock: true);
      if (retryAfter) refresh();
    });
  }

  /// The current snapshot marked stale, for keep-last-known display.
  UsageSnapshot? _stale() => state.snapshot?.copyWith(stale: true);

  /// Canned data for [kFakeUsage] dev runs — exercises every popover row.
  UsageSnapshot _fakeSnapshot() {
    final now = DateTime.now();
    return UsageSnapshot(
      session: UsageWindow(
        percent: 42,
        resetsAt: now.add(const Duration(hours: 3)),
        label: 'Session',
      ),
      weekly: UsageWindow(
        percent: 67,
        resetsAt: now.add(const Duration(days: 4)),
        label: 'Weekly',
      ),
      opus: const UsageWindow(percent: 18, label: 'Opus · weekly'),
      sonnet: const UsageWindow(percent: 55, label: 'Sonnet · weekly'),
      plan: 'Max',
      fetchedAt: now,
    );
  }
}

final usageControllerProvider = NotifierProvider<UsageController, UsageState>(
  UsageController.new,
);
