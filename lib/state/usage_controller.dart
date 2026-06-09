import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/credentials_reader.dart';
import '../data/usage_api.dart';
import '../models/usage_error.dart';
import '../models/usage_snapshot.dart';
import '../settings/prefs.dart';

/// The single source of truth for usage data, listened to by both the tray
/// controller and the popover UI (spec §4).
class UsageState {
  final UsageSnapshot? snapshot;
  final UsageError? error;
  final bool loading;

  const UsageState({this.snapshot, this.error, this.loading = false});

  const UsageState.loading() : snapshot = null, error = null, loading = true;

  UsageState copyWith({
    UsageSnapshot? snapshot,
    UsageError? error,
    bool? loading,
    bool clearError = false,
  }) {
    return UsageState(
      snapshot: snapshot ?? this.snapshot,
      error: clearError ? null : (error ?? this.error),
      loading: loading ?? this.loading,
    );
  }
}

final credentialsReaderProvider =
    Provider<CredentialsReader>((ref) => CredentialsReader());

final usageApiProvider = Provider<UsageApi>((ref) => UsageApi());

class UsageController extends Notifier<UsageState> {
  Timer? _timer;

  @override
  UsageState build() {
    final minutes = ref.watch(settingsProvider.select((s) => s.refreshMinutes));

    ref.onDispose(() => _timer?.cancel());
    _timer?.cancel();
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => refresh());

    // Kick off the first load after the notifier is constructed.
    Future.microtask(refresh);

    return const UsageState.loading();
  }

  /// Reads credentials, fetches usage, and updates state. On network failure
  /// the last snapshot is kept and marked stale (spec §11).
  Future<void> refresh() async {
    state = state.copyWith(loading: true);

    final credResult = await ref.read(credentialsReaderProvider).read();
    if (!credResult.isOk) {
      state = UsageState(
        snapshot: _stale(),
        error: credResult.error,
        loading: false,
      );
      return;
    }

    final usageResult = await ref.read(usageApiProvider).fetch(credResult.credentials!);
    if (usageResult.isOk) {
      state = UsageState(snapshot: usageResult.snapshot, loading: false);
    } else {
      state = UsageState(
        snapshot: _stale(),
        error: usageResult.error,
        loading: false,
      );
    }
  }

  /// The current snapshot marked stale, for keep-last-known display.
  UsageSnapshot? _stale() => state.snapshot?.copyWith(stale: true);
}

final usageControllerProvider =
    NotifierProvider<UsageController, UsageState>(UsageController.new);
