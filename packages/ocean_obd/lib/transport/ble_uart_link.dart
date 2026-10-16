import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'byte_link.dart';

/// ELM327-over-BLE "UART": one characteristic we write commands to and one we
/// get notifications from. Adapters differ in UUIDs (18F0/2AF1/2AF0 on the
/// vLinker FD+, FFF0/FFF1/FFF2, FFE0/FFE1, vendor 128-bit), so the pair is
/// discovered rather than hard-coded, preferring a service that has both.
class BleUartLink implements ByteLink {
  BleUartLink._(this.device, this.writeChar, this.notifyChar, this._sub, this._controller);

  final BluetoothDevice device;
  final BluetoothCharacteristic writeChar;
  final BluetoothCharacteristic notifyChar;
  final StreamSubscription<List<int>> _sub;
  final StreamController<List<int>> _controller;

  /// Human-readable description of the chosen characteristics, for the UI.
  String get description =>
      'svc ${writeChar.serviceUuid.str} write ${writeChar.uuid.str} notify ${notifyChar.uuid.str}';

  // 18F0 (write 2AF1, notify 2AF0) is the vLinker FD+'s service.
  static const _preferredServices = ['18f0', 'fff0', 'ffe0'];
  static const _ignoredServices = ['1800', '1801', '180a', '180f'];

  static Future<BleUartLink> connect(BluetoothDevice device) async {
    // Personal, non-commercial use (flutter_blue_plus licence, PLAN.md §7).
    await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 15));
    final services = await device.discoverServices();

    final candidates = services
        .where((s) => !_ignoredServices.contains(s.uuid.str.toLowerCase()))
        .toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));

    for (final s in candidates) {
      final notify = s.characteristics
          .where((c) => c.properties.notify || c.properties.indicate)
          .firstOrNull;
      final write = s.characteristics
          .where((c) => c.properties.write || c.properties.writeWithoutResponse)
          .firstOrNull;
      if (notify == null || write == null) continue;

      final controller = StreamController<List<int>>();
      final sub = notify.onValueReceived.listen(controller.add);
      device.cancelWhenDisconnected(sub);
      await notify.setNotifyValue(true);
      return BleUartLink._(device, write, notify, sub, controller);
    }

    await device.disconnect();
    throw StateError('No UART-style service found on ${device.platformName}');
  }

  static int _rank(BluetoothService s) {
    final i = _preferredServices.indexOf(s.uuid.str.toLowerCase());
    return i == -1 ? _preferredServices.length : i;
  }

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final withoutResponse =
        !writeChar.properties.write && writeChar.properties.writeWithoutResponse;
    // Commands are short, but stay under the default 20-byte ATT payload.
    for (var i = 0; i < bytes.length; i += 20) {
      final end = i + 20 > bytes.length ? bytes.length : i + 20;
      await writeChar.write(bytes.sublist(i, end), withoutResponse: withoutResponse);
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    await _controller.close();
    await device.disconnect();
  }
}
