import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cli_usage_source.dart';
import '../models/usage_error.dart';
import '../models/usage_snapshot.dart';
import '../models/usage_window.dart';
import '../settings/prefs.dart';

/// Serves canned usage data instead of spawning the real `claude` CLI. Off
/// by default; pass `--dart-define=CLAUDEBAR_FAKE_USAGE=true` for UI work on
/// machines without Claude Code, or to exercise every popover row.
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

final cliUsageSourceProvider = Provider<CliUsageSource>(
  (ref) => CliUsageSource(),
);

class UsageController extends Notifier<UsageState> {
  /// Minimum gap between refreshes once one succeeds — usage data doesn't
  /// move faster than this, and the endpoint's quota has proven tight enough
  /// that even a single extra request minutes after the last one can 429.
  static const _cooldown = Duration(seconds: 60);

  /// The CLI gates its usage fetch to ~once every few minutes, keyed on the
  /// last *successful* fetch and account-wide (the user's own Claude Code
  /// sessions reset it too). A probe inside that window returns only the
  /// preamble (UsageErrorKind.noData) — cheaply, with no API call and without
  /// pushing the gate out. So on noData we retry on this short cadence to catch
  /// the gate the moment it opens, instead of waiting out the full refresh
  /// interval and staying stuck on the last reading.
  static const _retryDelay = Duration(seconds: 45);

  /// Keep showing the last good reading as current until it's older than this
  /// (~2 fetch-gate cycles). Its "As of HH:MM" already carries the real age;
  /// only past here is a noData failure worth the "No fresh reading" banner.
  static const _staleAfter = Duration(minutes: 11);

  Timer? _timer;
  Timer? _unlockTimer;
  Timer? _retryTimer;
  bool _refreshing = false;

  @override
  UsageState build() {
    final minutes = ref.watch(settingsProvider.select((s) => s.refreshMinutes));

    ref.onDispose(() {
      _timer?.cancel();
      _unlockTimer?.cancel();
      _retryTimer?.cancel();
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

  /// Probes the CLI for usage and updates state. On failure the last snapshot
  /// is kept (spec §11) — marked stale, except a gated [UsageErrorKind.noData]
  /// reply, which stays current within its grace window and is retried fast.
  ///
  /// The app, not the caller, owns the request rate: calls are dropped while
  /// a fetch is in flight, during the post-success cooldown, and during a 429
  /// backoff window — so neither button-mashing nor the periodic timer can
  /// hammer the endpoint.
  Future<void> refresh() async {
    if (_refreshing || state.locked) return;
    _refreshing = true;
    // A refresh is starting now — drop any queued fast retry; this run (or the
    // success cooldown it sets) supersedes it.
    _retryTimer?.cancel();
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

    // The CLI is the only source: `claude -p "/usage"` reads credentials
    // inside Claude Code's own process, so it can never trip the macOS
    // Keychain password prompt. Failures come back classified (no CLI /
    // signed out / offline / format changed) — deliberately no silent
    // fallback, which would mask which one happened.
    final result = await ref.read(cliUsageSourceProvider).fetch();
    if (result.isOk) {
      final fresh = result.snapshot!;
      state = UsageState(snapshot: fresh, loading: false);
      _lock(_cooldown);
    } else {
      // Keep-last-known (spec §11). For a noData failure — the CLI answered but
      // its fetch was gated — the last reading is still the latest available, so
      // keep showing it as current until it's genuinely old (its "As of HH:MM"
      // carries the age), and retry soon to catch the gate when it opens. Other
      // failures (offline / signed out / format changed) mark it stale at once.
      final err = result.error;
      final last = state.snapshot;
      final transient = err?.kind == UsageErrorKind.noData;
      final fresh = keepLastFresh(err?.kind, last, DateTime.now());
      state = UsageState(
        snapshot: fresh ? last : _stale(),
        error: err,
        loading: false,
      );
      if (transient) _scheduleRetry();
    }
  }

  /// One-shot fast retry after a gated (noData) probe, replacing any pending
  /// one. Cheap — a gated probe makes no API call — so this just races to catch
  /// the fetch gate the moment it reopens.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, refresh);
  }

  /// Whether a failed refresh should keep showing [last] as the current reading
  /// (true) or mark it stale (false). Only a gated [UsageErrorKind.noData] reply
  /// — where the last reading is still the latest the CLI can offer — keeps the
  /// reading, and only until it's older than [_staleAfter]. Every other failure,
  /// or no prior reading, falls through to stale.
  @visibleForTesting
  static bool keepLastFresh(
    UsageErrorKind? kind,
    UsageSnapshot? last,
    DateTime now,
  ) {
    if (kind != UsageErrorKind.noData || last == null) return false;
    return now.difference(last.fetchedAt) < _staleAfter;
  }

  /// Blocks refreshes for [duration] and schedules the unlock.
  void _lock(Duration duration) {
    _unlockTimer?.cancel();
    state = state.copyWith(lockedUntil: DateTime.now().add(duration));
    _unlockTimer = Timer(duration, () {
      state = state.copyWith(clearLock: true);
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
