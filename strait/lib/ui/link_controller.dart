import 'dart:async';

import 'package:flutter/foundation.dart';

import '../abrp/abrp_client.dart';
import '../abrp/credentials.dart';
import '../abrp/live_poller.dart';
import '../abrp/uploader.dart';
import '../abrp/vehicle_state.dart';
import 'package:ocean_obd/platform/background.dart';
import 'package:ocean_obd/platform/gps_fix.dart';
import 'package:ocean_obd/signals/signal_table.dart';
import 'package:ocean_obd/ui/connect_controller.dart';

/// Drives the ABRP tab (PLAN.md §5): credentials, and the live link that
/// polls the car and uploads to ABRP.
class LinkController extends ChangeNotifier {
  LinkController({
    required this.connect,
    required this.table,
    required this.store,
    AbrpClient Function(AbrpCredentials)? clientFactory,
    Stream<GpsFix> Function()? gps,
  })  : _clientFactory = clientFactory ?? ((c) => AbrpClient(c)),
        _gps = gps ?? Background.gpsFixes;

  final ConnectController connect;
  final SignalTable table;
  final CredentialStore store;
  final AbrpClient Function(AbrpCredentials) _clientFactory;
  final Stream<GpsFix> Function() _gps;

  AbrpCredentials? credentials;
  String? error;
  String? checkResult;
  bool checking = false;

  VehicleState? vehicle;
  LivePoller? _poller;
  AbrpUploader? _uploader;
  AbrpClient? _client;
  StreamSubscription<GpsFix>? _gpsSub;
  DateTime _lastNotify = DateTime(0);

  bool get linking => _uploader != null;
  bool get hasCredentials => credentials?.isComplete ?? false;
  LivePollerStats? get pollerStats => _poller?.stats;
  AbrpUploader? get uploader => _uploader;

  /// Verified signals that go to ABRP.
  List<SignalDef> get abrpSignals => [
        for (final s in table.signals)
          if (s.verified && s.abrpField != null && s.pollSeconds > 0) s,
      ];

  Future<void> load() async {
    try {
      credentials = await store.load();
    } catch (e) {
      error = 'Could not read saved ABRP settings: $e';
    }
    notifyListeners();
  }

  Future<void> saveCredentials({required String apiKey, required String token}) async {
    final c = AbrpCredentials(apiKey: apiKey.trim(), token: token.trim());
    if (!c.isComplete) {
      error = 'Enter both the API key and the token.';
      notifyListeners();
      return;
    }
    await store.save(c);
    credentials = c;
    error = null;
    notifyListeners();
  }

  Future<void> clearCredentials() async {
    await stop();
    await store.clear();
    credentials = null;
    checkResult = null;
    notifyListeners();
  }

  Future<void> start() async {
    if (linking) return;
    final creds = credentials;
    if (creds == null || !creds.isComplete) {
      error = 'Enter your ABRP API key and token first.';
      notifyListeners();
      return;
    }
    if (connect.uds == null) {
      error = 'Connect to the adapter first (Connect tab).';
      notifyListeners();
      return;
    }
    error = null;
    final permError = await Background.requestPermissions();
    if (permError != null) {
      error = permError;
      notifyListeners();
      return;
    }

    final vehicle = this.vehicle = VehicleState();
    final client = _client = _clientFactory(creds);
    final poller = _poller = LivePoller(
      uds: () => connect.uds,
      signals: table.signals,
      state: vehicle,
    )..onUpdate = _throttledNotify;
    poller.onCarOffTimeout = () async {
      error = 'The car has been off for 10 minutes, so the link stopped. '
          'Press Start next time you drive.';
      await stop();
      await connect.disconnect();
    };
    final uploader = _uploader = AbrpUploader(client: client, snapshot: vehicle.snapshot)
      ..onUpdate = _throttledNotify;
    _gpsSub = _gps().listen(vehicle.updateGps, onError: (_) {});

    final fgsError = await Background.start('abrp', 'Sending live data to ABRP');
    if (fgsError != null) error = 'Background service: $fgsError';
    unawaited(poller.run().catchError((Object e) {
      error = 'Car polling stopped: $e';
      notifyListeners();
    }));
    unawaited(uploader.run().catchError((Object e) {
      error = 'Uploading stopped: $e';
      notifyListeners();
    }));
    notifyListeners();
  }

  Future<void> stop() async {
    _poller?.stop();
    _uploader?.stop();
    await _gpsSub?.cancel();
    _gpsSub = null;
    _poller = null;
    _uploader = null;
    _client?.close();
    _client = null;
    await Background.stop('abrp');
    notifyListeners();
  }

  /// Reads back what ABRP holds for this token. ABRP processes data with a
  /// 60 s delay, so new points show up a minute or two after sending.
  Future<void> checkAbrp() async {
    final creds = credentials;
    if (creds == null || !creds.isComplete || checking) return;
    checking = true;
    checkResult = null;
    notifyListeners();
    final client = _clientFactory(creds);
    try {
      final r = await client.getTelemetry();
      checkResult = r.ok ? describeTelemetry(r.result) : 'ABRP: ${r.message}';
    } finally {
      client.close();
      checking = false;
      notifyListeners();
    }
  }

  /// A short summary of a `get_telemetry` result.
  static String describeTelemetry(Object? result) {
    if (result is! Map) return 'ABRP has no telemetry for this car yet.';
    final tlm = result['telemetry'] is Map ? result['telemetry'] as Map : result;
    final utc = tlm['utc'];
    final parts = <String>[];
    if (utc is num) {
      final at = DateTime.fromMillisecondsSinceEpoch((utc * 1000).round());
      final age = DateTime.now().difference(at);
      parts.add('latest point ${_ago(age)} ago');
    }
    for (final (key, label) in [('soc', 'SOC'), ('speed', 'speed'), ('power', 'power')]) {
      if (tlm[key] != null) parts.add('$label ${tlm[key]}');
    }
    return parts.isEmpty ? 'ABRP answered, but without telemetry.' : 'ABRP has: ${parts.join(', ')}';
  }

  static String _ago(Duration d) {
    if (d.inSeconds < 90) return '${d.inSeconds} s';
    if (d.inMinutes < 90) return '${d.inMinutes} min';
    return '${d.inHours} h';
  }

  void _throttledNotify() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) < const Duration(milliseconds: 500)) return;
    _lastNotify = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _poller?.stop();
    _uploader?.stop();
    _gpsSub?.cancel();
    super.dispose();
  }
}
