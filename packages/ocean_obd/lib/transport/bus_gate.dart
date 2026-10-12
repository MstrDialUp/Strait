/// Keeps the car asleep (PLAN.md §5.4): bus traffic is only allowed while a
/// recent `ATRV` reading shows the DC-DC converter running, or while the
/// car is known to be driving.
///
/// Driving counts as on because the 12 V supply can sit just under
/// [onThresholdVolts] on the move (12.9 V seen on 2026-10-11). A speed of at
/// least [movingKmh] (GPS, or the car's own speed reading) keeps the gate
/// open for [motionHold] after the last such reading, so stops at lights
/// don't close it. Speed can't be renewed once the car is parked, so this
/// can't keep a parked car awake for longer than [motionHold].
class BusGate {
  BusGate({
    this.onThresholdVolts = 13.0,
    this.maxReadingAge = const Duration(seconds: 90),
    this.movingKmh = 10,
    this.motionHold = const Duration(minutes: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final double onThresholdVolts;
  final Duration maxReadingAge;
  final double movingKmh;
  final Duration motionHold;
  final DateTime Function() _clock;

  double? _volts;
  DateTime? _readAt;
  double? _speed;
  DateTime? _movingAt;

  double? get lastVolts => _volts;
  DateTime? get lastReadAt => _readAt;

  /// The last speed that counted as driving.
  double? get lastMovingKmh => _speed;

  void recordVoltage(double volts) {
    _volts = volts;
    _readAt = _clock();
  }

  /// Records a speed reading in km/h. Only speeds of at least [movingKmh]
  /// count; slower ones leave the hold running out.
  void recordSpeed(double kmh) {
    if (kmh < movingKmh) return;
    _speed = kmh;
    _movingAt = _clock();
  }

  /// Forces the gate shut until the next voltage or speed reading, e.g.
  /// after a UDS request goes unanswered.
  void close() {
    _volts = null;
    _readAt = null;
    _speed = null;
    _movingAt = null;
  }

  /// A recent ATRV reading shows the car on.
  bool get voltageOn {
    final v = _volts;
    final t = _readAt;
    if (v == null || t == null) return false;
    return v >= onThresholdVolts && _clock().difference(t) <= maxReadingAge;
  }

  /// The car was driving within the last [motionHold].
  bool get moving {
    final t = _movingAt;
    return t != null && _clock().difference(t) <= motionHold;
  }

  bool get isOpen => voltageOn || moving;
}
