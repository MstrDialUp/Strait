import 'dart:async';
import 'dart:convert';

import '../transport/byte_link.dart';

/// A scripted ELM327: replies to each command from [replies] (or with
/// [defaultReply]) followed by the `>` prompt, optionally split into chunks
/// to mimic BLE notifications.
class FakeElm implements ByteLink {
  FakeElm({Map<String, String>? replies, this.handler, this.defaultReply = 'OK', this.chunkSize = 7})
      : replies = replies ?? {};

  final Map<String, String> replies;

  /// Consulted before [replies]; return null to fall through.
  final String? Function(String cmd)? handler;
  final String defaultReply;
  final int chunkSize;

  /// Commands received, without the trailing `\r`.
  final sent = <String>[];

  /// When false, commands get no reply at all (to test timeouts).
  bool responsive = true;

  /// Commands whose reply is held back this long (to test late replies).
  final delays = <String, Duration>{};

  /// When true, writes throw, like a dropped BLE link.
  bool linkDown = false;

  final _incoming = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    if (linkDown) throw StateError('Device is disconnected');
    final text = ascii.decode(bytes);
    if (_monitoring) {
      // Any character stops ATMA.
      _monitoring = false;
      sent.add(text);
      _emit('\r>');
      return;
    }
    final cmd = text.replaceAll('\r', '');
    sent.add(cmd);
    if (!responsive) return;
    if (cmd == 'ATMA' && monitorLines != null) {
      _monitoring = true;
      _emit(monitorLines!.map((l) => '$l\r').join());
      return;
    }
    _emit('${handler?.call(cmd) ?? replies[cmd] ?? defaultReply}\r\r>', delays[cmd]);
  }

  /// Lines ATMA streams until interrupted; null means ATMA replies like any
  /// other command.
  List<String>? monitorLines;
  bool _monitoring = false;

  void _emit(String reply, [Duration? delay]) {
    final data = ascii.encode(reply);
    void send() {
      for (var i = 0; i < data.length; i += chunkSize) {
        _incoming.add(data.sublist(i, i + chunkSize > data.length ? data.length : i + chunkSize));
      }
    }

    delay == null ? scheduleMicrotask(send) : Timer(delay, send);
  }

  @override
  Future<void> close() => _incoming.close();
}
