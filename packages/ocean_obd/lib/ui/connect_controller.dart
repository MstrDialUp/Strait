import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../elm/elm_client.dart';
import '../elm/elm_response.dart';
import '../signals/signal_table.dart';
import '../transport/ble_uart_link.dart';
import '../transport/elm_transport.dart';
import '../uds/uds_client.dart';

enum LinkState { idle, scanning, connecting, connected, reconnecting, failed }

/// Wait before each reconnect attempt; the last value repeats.
const reconnectBackoff = [2, 5, 10, 20, 30];

/// How often ATRV is re-read while connected, so the car-on reading never
/// goes stale (the bus gate trusts a reading for 90 s). ATRV reads the
/// adapter's supply pin and sends nothing on the CAN bus.
const voltageRefresh = Duration(seconds: 30);

/// Result of reading one known signal, for display next to the dash value.
class SignalReading {
  SignalReading(this.signal, this.result, {this.value, this.error});

  final SignalDef signal;
  final ReadResult? result;
  final Object? value;
  final String? error;

  String get rawHex => switch (result) {
        ReadValue(:final data) => bytesToHex(data),
        _ => '',
      };

  String get status => switch (result) {
        ReadValue() => error ?? 'ok',
        ReadNegative(:final nrc, :final description) =>
          'NRC 0x${nrc.toRadixString(16).padLeft(2, '0').toUpperCase()} $description',
        ReadNoResponse(:final reason) => 'no response ($reason)',
        null => error ?? '',
      };
}

/// Drives the Connect screen: scan, connect, ELM setup, ATRV and reading the
/// known values (PLAN.md §4.1, screen 1).
class ConnectController extends ChangeNotifier {
  ConnectController(this.table);

  final SignalTable table;

  LinkState state = LinkState.idle;
  String? error;
  List<ScanResult> scanResults = [];
  String? adapterId;
  String? linkDescription;
  double? volts;
  bool busy = false;
  List<SignalReading> readings = [];
  final trace = <String>[];

  BleUartLink? _link;
  ElmTransport? _transport;
  ElmClient? _elm;
  UdsClient? _uds;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _voltageTimer;

  /// The adapter to reconnect to after an unexpected drop.
  BluetoothDevice? _device;
  int reconnectAttempts = 0;

  bool get carOn => _transport?.gate.isOpen ?? false;

  /// The live UDS client while connected, shared with Discover and Record.
  UdsClient? get uds => state == LinkState.connected ? _uds : null;

  /// Reads the VIN if the car is on; null otherwise.
  Future<String?> readVin() async {
    final u = uds;
    final vin = table.byId('vin');
    if (u == null || vin == null || !carOn) return null;
    try {
      final r = await u.readDid(vin.module, vin.did);
      return r is ReadValue ? vin.decode(r.data) as String : null;
    } catch (_) {
      return null;
    }
  }

  /// Lets other screens refresh the connect view after an ATRV check.
  void refresh() => notifyListeners();

  static bool looksLikeAdapter(ScanResult r) {
    final name = r.device.platformName.toLowerCase();
    return name.contains('vlink') || name.contains('obd') || name.contains('elm');
  }

  Future<void> startScan() async {
    error = null;
    scanResults = [];
    state = LinkState.scanning;
    notifyListeners();
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      scanResults = results.where((r) => r.device.platformName.isNotEmpty).toList()
        ..sort((a, b) {
          final byAdapter = (looksLikeAdapter(b) ? 1 : 0) - (looksLikeAdapter(a) ? 1 : 0);
          return byAdapter != 0 ? byAdapter : b.rssi.compareTo(a.rssi);
        });
      notifyListeners();
    });
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (e) {
      _fail('Scan failed: $e');
      return;
    }
    if (state == LinkState.scanning) {
      state = LinkState.idle;
      notifyListeners();
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    state = LinkState.connecting;
    error = null;
    trace.clear();
    notifyListeners();
    try {
      await _open(device);
      _device = device;
      state = LinkState.connected;
    } catch (e) {
      await _teardown();
      _fail('Connect failed: $e');
    }
    notifyListeners();
  }

  /// Connects the BLE link and runs the adapter setup. Sends nothing on the
  /// CAN bus.
  Future<void> _open(BluetoothDevice device) async {
    final link = _link = await BleUartLink.connect(device);
    linkDescription = link.description;
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && state == LinkState.connected) {
        _reconnect();
      }
    });
    final transport = _transport = ElmTransport(link)..onTrace = _addTrace;
    final elm = _elm = ElmClient(transport);
    _uds = UdsClient(elm);
    await elm.initialize();
    adapterId = await elm.adapterId();
    volts = await elm.readVoltage();
    _voltageTimer?.cancel();
    _voltageTimer = Timer.periodic(voltageRefresh, (_) => _refreshVoltage());
  }

  /// Re-reads ATRV in the background unless someone else (the ABRP link,
  /// the recorder) read it recently. Leaves [error] alone.
  Future<void> _refreshVoltage() async {
    final elm = _elm;
    if (elm == null || state != LinkState.connected) return;
    final last = elm.transport.gate.lastReadAt;
    if (!busy && (last == null || DateTime.now().difference(last) >= voltageRefresh)) {
      try {
        volts = await elm.readVoltage();
      } catch (_) {
        // A dropped link is handled by the reconnect logic.
      }
    } else {
      volts = elm.transport.gate.lastVolts ?? volts;
    }
    notifyListeners();
  }

  /// After an unexpected drop, retries with [reconnectBackoff] until it
  /// works or the user taps Disconnect. Recording keeps logging GPS
  /// meanwhile and resumes polling once [uds] is back.
  Future<void> _reconnect() async {
    final device = _device;
    if (device == null) return;
    state = LinkState.reconnecting;
    reconnectAttempts = 0;
    error = 'Adapter disconnected. Reconnecting…';
    _addTrace('link lost');
    await _teardown();
    notifyListeners();
    while (state == LinkState.reconnecting) {
      final wait = reconnectBackoff[
          reconnectAttempts < reconnectBackoff.length ? reconnectAttempts : reconnectBackoff.length - 1];
      await Future<void>.delayed(Duration(seconds: wait));
      if (state != LinkState.reconnecting) return;
      reconnectAttempts++;
      notifyListeners();
      try {
        await _open(device);
        if (state != LinkState.reconnecting) {
          await _teardown(); // user gave up while we were connecting
          return;
        }
        state = LinkState.connected;
        error = null;
        _addTrace('reconnected after $reconnectAttempts attempt(s)');
      } catch (e) {
        await _teardown();
        error = 'Adapter disconnected. Reconnect attempt $reconnectAttempts failed: $e';
      }
      notifyListeners();
    }
  }

  /// Re-reads ATRV (nothing is sent on the CAN bus).
  Future<void> checkVoltage() => _guard(() async {
        volts = await _elm!.readVoltage();
      });

  /// Reads each known signal once. Only runs if ATRV shows the car on.
  Future<void> readKnownValues() => _guard(() async {
        volts = await _elm!.readVoltage();
        if (!carOn) {
          error = 'Car appears off (${volts?.toStringAsFixed(1) ?? '?'} V). '
              'Nothing sent on the bus.';
          return;
        }
        readings = [];
        for (final s in table.signals) {
          readings.add(await _readSignal(s));
          notifyListeners();
        }
        if (readings.every((r) => r.result is ReadNoResponse)) {
          // PLAN.md §5.4: no answers → stop and fall back to the ATRV check.
          _transport!.gate.close();
          error = 'No module answered. Stopped; check the car is in Ready.';
        }
      });

  Future<SignalReading> _readSignal(SignalDef s) async {
    try {
      final r = await _uds!.readDid(s.module, s.did);
      if (r is ReadValue) {
        try {
          return SignalReading(s, r, value: s.decode(r.data));
        } on SignalDecodeException catch (e) {
          return SignalReading(s, r, error: e.message);
        }
      }
      return SignalReading(s, r);
    } catch (e) {
      return SignalReading(s, null, error: '$e');
    }
  }

  Future<void> disconnect() async {
    state = LinkState.idle; // also stops a reconnect loop
    _device = null;
    await _teardown();
    readings = [];
    adapterId = null;
    volts = null;
    notifyListeners();
  }

  Future<void> _guard(Future<void> Function() body) async {
    if (busy || _elm == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _addTrace(String line) {
    trace.add(line);
    if (trace.length > 300) trace.removeRange(0, trace.length - 300);
    notifyListeners();
  }

  void _fail(String message) {
    error = message;
    state = LinkState.failed;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _voltageTimer?.cancel();
    _voltageTimer = null;
    await _connSub?.cancel();
    _connSub = null;
    final t = _transport;
    _transport = null;
    _elm = null;
    _uds = null;
    try {
      if (t != null) {
        await t.close();
      } else {
        await _link?.close();
      }
    } catch (_) {}
    _link = null;
  }

  @override
  void dispose() {
    _voltageTimer?.cancel();
    _scanSub?.cancel();
    _teardown();
    super.dispose();
  }
}
