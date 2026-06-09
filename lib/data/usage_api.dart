import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/credentials.dart';
import '../models/usage_error.dart';
import '../models/usage_snapshot.dart';
import '../models/usage_window.dart';

/// Result of a usage fetch: a snapshot on success, or a [UsageError].
class UsageResult {
  final UsageSnapshot? snapshot;
  final UsageError? error;

  const UsageResult.ok(this.snapshot) : error = null;
  const UsageResult.fail(this.error) : snapshot = null;

  bool get isOk => snapshot != null;
}

/// Calls `GET /api/oauth/usage` and parses it defensively (spec §8).
///
/// The exact sub-field names of each window are not 100% confirmed, so the
/// parser tries several candidate keys and normalizes the percentage to
/// 0–100 regardless of whether the source is a 0–1 fraction or already 0–100.
class UsageApi {
  UsageApi({http.Client? client, DateTime Function()? now})
      : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  static final Uri _endpoint =
      Uri.parse('https://api.anthropic.com/api/oauth/usage');

  final http.Client _client;
  final DateTime Function() _now;

  Future<UsageResult> fetch(ClaudeCredentials creds) async {
    http.Response res;
    try {
      res = await _client.get(_endpoint, headers: {
        'Authorization': 'Bearer ${creds.accessToken}',
        'anthropic-beta': 'oauth-2025-04-20',
      }).timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[ClaudeBar] usage fetch failed: $e');
      return const UsageResult.fail(UsageError.network);
    }

    if (res.statusCode == 401) {
      return const UsageResult.fail(UsageError.expiredToken);
    }
    if (res.statusCode != 200) {
      debugPrint('[ClaudeBar] usage endpoint ${res.statusCode}: ${res.body}');
      return const UsageResult.fail(UsageError.network);
    }

    if (kDebugMode) {
      // VERIFY step: log the raw payload once so the field mapping can be
      // confirmed against reality (spec §3a / Phase 1).
      debugPrint('[ClaudeBar] raw /api/oauth/usage: ${res.body}');
    }

    try {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return UsageResult.ok(_parse(json, creds));
    } catch (e) {
      debugPrint('[ClaudeBar] usage parse failed: $e');
      return const UsageResult.fail(UsageError.network);
    }
  }

  UsageSnapshot _parse(Map<String, dynamic> json, ClaudeCredentials creds) {
    final session = _window(json['five_hour'], 'Session') ??
        const UsageWindow(percent: 0, label: 'Session');
    final weekly = _window(json['seven_day'], 'Weekly') ??
        const UsageWindow(percent: 0, label: 'Weekly');
    final opus = _window(json['seven_day_opus'], 'Opus · weekly');
    final sonnet = _window(json['seven_day_sonnet'], 'Sonnet · weekly');

    return UsageSnapshot(
      session: session,
      weekly: weekly,
      opus: opus,
      sonnet: sonnet,
      plan: creds.planLabel,
      fetchedAt: _now(),
    );
  }

  /// Parses one window object into a [UsageWindow], or null if absent.
  UsageWindow? _window(dynamic raw, String label) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    return UsageWindow(
      percent: _percent(map),
      resetsAt: _resetsAt(map),
      label: label,
    );
  }

  /// Extracts a percentage from a window map.
  ///
  /// The live endpoint reports `utilization` already on a 0–100 scale (e.g.
  /// `24.0`), verified against real data — so we do NOT rescale, which would
  /// otherwise inflate a genuine low value like `0.5` into `50`. Other key
  /// names and a used/limit fallback are tried defensively in case the shape
  /// shifts.
  double _percent(Map<String, dynamic> map) {
    const candidates = [
      'utilization',
      'percent',
      'percentage',
      'used_pct',
      'used_percent',
      'usage',
    ];
    num? value;
    for (final key in candidates) {
      final v = map[key];
      if (v is num) {
        value = v;
        break;
      }
    }
    // Fallback: derive from used / limit if present.
    if (value == null) {
      final used = map['used'] ?? map['used_tokens'];
      final limit = map['limit'] ?? map['max'] ?? map['total'];
      if (used is num && limit is num && limit > 0) {
        value = used / limit * 100;
      }
    }
    if (value == null) return 0;
    return value.toDouble().clamp(0, 100).toDouble();
  }

  /// Extracts a reset time (ISO string or epoch) from a window map.
  DateTime? _resetsAt(Map<String, dynamic> map) {
    const candidates = ['resets_at', 'reset_at', 'resetsAt', 'reset'];
    for (final key in candidates) {
      final v = map[key];
      if (v is String) {
        final asInt = int.tryParse(v);
        if (asInt != null) return _fromEpoch(asInt);
        final parsed = DateTime.tryParse(v);
        if (parsed != null) return parsed;
      } else if (v is int) {
        return _fromEpoch(v);
      }
    }
    return null;
  }

  DateTime _fromEpoch(int value) {
    return value > 1000000000000
        ? DateTime.fromMillisecondsSinceEpoch(value)
        : DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }
}
