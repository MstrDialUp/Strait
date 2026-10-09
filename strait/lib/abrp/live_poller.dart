import 'dart:async';

import 'package:ocean_obd/elm/elm_client.dart';
import 'package:ocean_obd/signals/signal_table.dart';
import 'package:ocean_obd/transport/elm_transport.dart';
import 'package:ocean_obd/uds/uds_client.dart';
import 'vehicle_state.dart';

/// One entry in the link's diagnostic log.
class LinkEvent {
  LinkEvent(this.at, this.message);
  final DateTime at;
  final String message;
}

class LivePollerStats {
  double? volts;
  bool carOn = false;
  int reads = 0;
  int noResponses = 0;
  DateTime? carOffSince;
  String status = '';

  /// Why the link decided what it did (car on/off, unanswered reads,
  /// timeouts), oldest first, capped at [maxEvents].
  final events = <LinkEvent>[];
  static const maxEvents = 40;
}

/// Polls the verified ABRP signals into a [VehicleState] (PLAN.md §5.1,
/// §5.4).
///
/// Nothing goes on the bus unless ATRV shows the car on. While the car is
/// on, a low or unreadable ATRV pauses polling and is re-checked every
/// [lowVoltageRecheck]; the car only counts as off after [offConfirmations]
/// such readings in a row. While the car is off, ATRV is re-read every
/// [carOffRecheck], or sooner if another screen gets a car-on reading;
/// after [carOffTimeout] of the car being off, [run] returns and
/// [onCarOffTimeout] fires so the caller can disconnect the adapter. A run
/// of [noResponseLimit] unanswered reads closes the bus gate until the next
/// voltage check.
class LivePoller {
  LivePoller({
    required this.uds,
    required List<SignalDef> signals,
    required this.state,
    DateTime Function()? clock,
    Duration Function(SignalDef)? intervalOf,
    this.voltageEvery = const Duration(seconds: 30),
    this.lowVoltageRecheck = const Duration(seconds: 5),
    this.offConfirmations = 3,
    this.carOffRecheck = const Duration(seconds: 60),
    this.carOffTimeout = const Duration(minutes: 10),
    this.linkRecheck = const Duration(seconds: 2),
    this.noResponseLimit = 10,
  })  : signals = [
          for (final s in signals)
            if (s.verified && s.abrpField != null && s.pollSeconds > 0) s,
        ],
        _clock = clock ?? DateTime.now,
        _intervalOf = intervalOf ?? ((s) => Duration(seconds: s.pollSeconds));

  final UdsClient? Function() uds;
  final List<SignalDef> signals;
  final VehicleState state;
  final DateTime Function() _clock;
  final Duration Function(SignalDef) _intervalOf;
  final Duration voltageEvery;
  final Duration lowVoltageRecheck;
  final int offConfirmations;
  final Duration carOffRecheck;
  final Duration carOffTimeout;
  final Duration linkRecheck;
  final int noResponseLimit;

  final stats = LivePollerStats();
  void Function()? onUpdate;
  void Function()? onCarOffTimeout;

  bool _stopping = false;
  Completer<void>? _wake;
  final _due = <SignalDef, DateTime>{};
  DateTime? _lastVoltage;
  UdsClient? _lastUds;
  int _streak = 0;
  int _lowReadings = 0;

  Future<void> run() async {
    _stopping = false;
    while (!_stopping) {
      await Future<void>.delayed(Duration.zero);
      final u = uds();
      if (u == null) {
        if (_lastUds != null) _log('Adapter disconnected');
        _lastUds = null;
        state.clearCar();
        stats.carOn = false;
        _set('Adapter disconnected: waiting for it');
        await _sleep(linkRecheck);
        continue;
      }
      if (!identical(u, _lastUds)) {
        _lastUds = u;
        _lastVoltage = null; // a new session's gate starts closed
      }
      final now = _clock();
      // A closed gate (stale reading, or closed by another screen) is
      // re-read before anything is decided.
      if (_lastVoltage == null ||
          now.difference(_lastVoltage!) >= voltageEvery ||
          !u.elm.transport.gate.isOpen) {
        await _checkVoltage(u);
      }
      if (stats.carOn && !u.elm.transport.gate.isOpen) {
        // Not confirmed off yet: keep the last values, send nothing on the
        // bus and check again soon.
        _set('Voltage check failed ($_lowReadings of $offConfirmations): re-checking');
        await _sleep(lowVoltageRecheck);
        _lastVoltage = null;
        continue;
      }
      if (!stats.carOn) {
        state.clearCar();
        final since = stats.carOffSince ??= now;
        if (now.difference(since) >= carOffTimeout) {
          _log('Car off for ${carOffTimeout.inMinutes} min: link stopped');
          _set('Car off for ${carOffTimeout.inMinutes} min: stopping');
          onCarOffTimeout?.call();
          return;
        }
        _set('Car off: nothing sent on the bus');
        await _waitWhileOff(u);
        _lastVoltage = null;
        continue;
      }
      stats.carOffSince = null;
      if (signals.isEmpty) {
        _set('No verified ABRP signals to poll');
        await _sleep(const Duration(seconds: 1));
        continue;
      }

      // Most overdue signal first.
      SignalDef? next;
      DateTime? nextAt;
      for (final s in signals) {
        final at = _due[s] ?? DateTime(0);
        if (nextAt == null || at.isBefore(nextAt)) {
          next = s;
          nextAt = at;
        }
      }
      final wait = nextAt!.difference(_clock());
      if (wait > Duration.zero) {
        await _sleep(wait < const Duration(seconds: 1) ? wait : const Duration(seconds: 1));
        continue;
      }
      _set('Polling ${signals.length} signals');
      await _poll(u, next!);
      _due[next] = _clock().add(_intervalOf(next));
      if (_streak >= noResponseLimit) {
        _log('No answer to $noResponseLimit reads in a row: stopped polling, '
            're-checking voltage');
        _streak = 0;
        u.elm.transport.gate.close();
        stats.carOn = false;
        _lastVoltage = null;
        await _sleep(const Duration(seconds: 10));
      }
      onUpdate?.call();
    }
  }

  void stop() {
    _stopping = true;
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _poll(UdsClient u, SignalDef s) async {
    try {
      final r = await u.readDid(s.module, s.did);
      stats.reads++;
      switch (r) {
        case ReadValue(:final data):
          _streak = 0;
          final v = s.decode(data);
          if (v is double) state.update(s.abrpField!, v);
        case ReadNegative():
          _streak = 0;
        case ReadNoResponse():
          _streak++;
          stats.noResponses++;
      }
    } on BusClosedException {
      // Another screen closed the gate; the loop re-reads ATRV next.
      _log('Bus gate closed before reading ${s.id}: re-checking voltage');
    } on ElmTimeoutException {
      _log('Adapter timeout reading ${s.id}');
      _streak++;
    } on ElmSetupException catch (e) {
      _log('Adapter refused setup for ${s.id}: ${e.command} → ${e.reply}');
      _streak++;
    } on SignalDecodeException {
      _streak = 0;
    } catch (e) {
      // Usually the BLE link dropping; the connect controller swaps the
      // session out.
      _log('Reading ${s.id} failed: $e');
      await _sleep(linkRecheck);
    }
  }

  Future<void> _checkVoltage(UdsClient u) async {
    String? failure;
    try {
      stats.volts = await u.elm.readVoltage();
      if (stats.volts == null) failure = 'ATRV reply unreadable';
    } catch (e) {
      stats.volts = null;
      failure = 'ATRV failed: $e';
    }
    _lastVoltage = _clock();
    final gate = u.elm.transport.gate;
    if (gate.isOpen) {
      if (failure != null) _log('$failure; the last reading is still recent');
      if (!stats.carOn) _log('Car on (${_volts(gate.lastVolts)})');
      stats.carOn = true;
      _lowReadings = 0;
      return;
    }
    _lowReadings++;
    if (!stats.carOn) return;
    _log('${failure ?? '${_volts(stats.volts)}, below '
        '${gate.onThresholdVolts.toStringAsFixed(1)} V'} '
        '($_lowReadings of $offConfirmations)');
    if (_lowReadings >= offConfirmations) {
      stats.carOn = false;
      _log('Car off');
    }
  }

  /// Waits [carOffRecheck] before the next ATRV, or less if another screen
  /// gets a car-on reading meanwhile (e.g. "Re-check voltage").
  Future<void> _waitWhileOff(UdsClient u) async {
    const slice = Duration(seconds: 1);
    var left = carOffRecheck;
    while (left > Duration.zero && !_stopping) {
      final step = left < slice ? left : slice;
      await _sleep(step);
      left -= step;
      if (u.elm.transport.gate.isOpen) return;
    }
  }

  static String _volts(double? v) => v == null ? '? V' : '${v.toStringAsFixed(1)} V';

  void _log(String message) {
    stats.events.add(LinkEvent(_clock(), message));
    if (stats.events.length > LivePollerStats.maxEvents) {
      stats.events.removeRange(0, stats.events.length - LivePollerStats.maxEvents);
    }
  }

  void _set(String status) {
    stats.status = status;
    onUpdate?.call();
  }

  Future<void> _sleep(Duration d) async {
    if (_stopping) return;
    final wake = _wake = Completer<void>();
    await Future.any([wake.future, Future<void>.delayed(d)]);
  }
}
