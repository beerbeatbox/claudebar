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

  /// Backoff steps for a *failed* probe that isn't the gated noData case — a
  /// killed/non-zero CLI run (surfaced as parseFailed), a network blip, an
  /// unknown error. These used to get no retry at all: the display went stale
  /// and stayed stale until the next interval tick, or until the user hit
  /// Refresh by hand — which is exactly the reported symptom, since one
  /// transient probe failure was enough to strand the reading. Retry soon,
  /// then back off, so a genuinely broken setup isn't probed every 30s.
  static const _errorBackoff = [
    Duration(seconds: 30),
    Duration(seconds: 90),
    Duration(minutes: 3),
    Duration(minutes: 5),
  ];

  /// How often the watchdog checks whether a refresh is due. The refresh
  /// schedule is wall-clock based (last attempt + interval) rather than a
  /// Timer.periodic on the interval itself: a background LSUIElement app gets
  /// its timers coalesced and suspended by macOS (App Nap, sleep/wake), so a
  /// periodic timer can silently skip whole intervals. A short watchdog that
  /// compares timestamps fires as soon as the app runs again, however long it
  /// was frozen.
  static const _watchdogPeriod = Duration(seconds: 20);

  /// A refresh in flight longer than this is treated as dead, so a probe that
  /// somehow never completes can't wedge `_refreshing` true forever and block
  /// every later refresh. Generously above the source's own 20s-per-spawn
  /// timeout (a failing fetch spawns at most three).
  static const _refreshWatchdog = Duration(minutes: 2);

  /// Keep showing the last good reading as current until it's older than this
  /// (~2 fetch-gate cycles). Its "As of HH:MM" already carries the real age;
  /// only past here is a noData failure worth the "No fresh reading" banner.
  static const _staleAfter = Duration(minutes: 11);

  Timer? _timer;
  Timer? _unlockTimer;
  Timer? _retryTimer;
  bool _refreshing = false;

  /// When the in-flight refresh started (null when none is running).
  DateTime? _startedAt;

  /// When the last refresh attempt began — the anchor for "is a refresh due?".
  DateTime? _lastAttempt;

  /// Consecutive failed probes, indexing into [_errorBackoff].
  int _failures = 0;

  /// The configured auto-refresh interval, mirrored out of settings so the
  /// watchdog can compare against it without re-reading the provider.
  Duration _interval = const Duration(minutes: 5);

  @override
  UsageState build() {
    final minutes = ref.watch(settingsProvider.select((s) => s.refreshMinutes));
    _interval = Duration(minutes: minutes);

    ref.onDispose(() {
      _timer?.cancel();
      _unlockTimer?.cancel();
      _retryTimer?.cancel();
    });
    _timer?.cancel();
    _timer = Timer.periodic(_watchdogPeriod, (_) => refreshIfDue());

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
    if (_inFlight || state.locked) return;
    _refreshing = true;
    _startedAt = DateTime.now();
    _lastAttempt = _startedAt;
    // A refresh is starting now — drop any queued fast retry; this run (or the
    // success cooldown it sets) supersedes it.
    _retryTimer?.cancel();
    try {
      await _refresh();
    } finally {
      _refreshing = false;
      _startedAt = null;
    }
  }

  /// True while a probe is genuinely running. A refresh that has been in
  /// flight past [_refreshWatchdog] is considered dead, so a wedged probe
  /// can't block refreshes for the rest of the run.
  bool get _inFlight {
    if (!_refreshing) return false;
    final started = _startedAt;
    if (started != null &&
        DateTime.now().difference(started) > _refreshWatchdog) {
      _refreshing = false;
      return false;
    }
    return true;
  }

  /// Refreshes only if the last attempt is at least one interval old. This is
  /// the auto-refresh schedule: driven by wall-clock comparison rather than by
  /// a timer that fires exactly on the interval, so suspended or coalesced
  /// timers (App Nap, sleep/wake) catch up instead of skipping a cycle.
  /// Also called when the popover opens and on the tray's minute tick, so the
  /// data is current the moment the user looks at it.
  void refreshIfDue() {
    final last = _lastAttempt;
    if (last != null && DateTime.now().difference(last) < _interval) return;
    refresh();
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
      _failures = 0;
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
      _failures = transient ? 0 : _failures + 1;
      _scheduleRetry(transient ? _retryDelay : _backoff());
    }
  }

  /// Backoff for the current failure streak, never longer than the configured
  /// interval — the watchdog would take over at that point anyway.
  Duration _backoff() {
    final step = _errorBackoff[
      (_failures - 1).clamp(0, _errorBackoff.length - 1)
    ];
    return step > _interval ? _interval : step;
  }

  /// One-shot retry after a failed probe, replacing any pending one. After a
  /// gated (noData) reply this is cheap — a gated probe makes no API call — so
  /// it just races to catch the fetch gate the moment it reopens; after a real
  /// failure it walks [_errorBackoff] so a stale reading recovers on its own
  /// instead of waiting for a manual Refresh.
  void _scheduleRetry(Duration delay) {
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, refresh);
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
      models: const [
        UsageWindow(percent: 18, label: 'Opus · weekly'),
        UsageWindow(percent: 55, label: 'Sonnet · weekly'),
        UsageWindow(percent: 7, label: 'Fable · weekly'),
      ],
      plan: 'Max',
      fetchedAt: now,
    );
  }
}

final usageControllerProvider = NotifierProvider<UsageController, UsageState>(
  UsageController.new,
);
