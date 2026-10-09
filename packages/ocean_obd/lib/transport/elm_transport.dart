import 'dart:async';
import 'dart:convert';

import 'bus_gate.dart';
import 'byte_link.dart';
import 'command_policy.dart';

class BusClosedException implements Exception {
  BusClosedException(this.command);
  final String command;

  @override
  String toString() =>
      'BusClosedException: "$command" not sent, car is not on (ATRV gate closed)';
}

class ElmTimeoutException implements Exception {
  ElmTimeoutException(this.command, this.partial);
  final String command;
  final String partial;

  @override
  String toString() => 'ElmTimeoutException: no ">" after "$command" (got "$partial")';
}

/// Sends one ELM327 command at a time and returns the reply text up to the
/// `>` prompt. Every command passes [CommandPolicy] and, if it touches the
/// bus, the [BusGate]. Bus requests are spaced at least [minBusInterval]
/// apart (PLAN.md §4.5: roughly 10-12 requests per second).
///
/// When a command times out, the adapter may still send its reply later.
/// That late reply is discarded (waiting up to [lateReplyWait] before the
/// next command is written), so it can't be taken as the next command's
/// reply and leave every reply after it one command behind.
class ElmTransport {
  ElmTransport(
    this._link, {
    BusGate? gate,
    this.minBusInterval = const Duration(milliseconds: 85),
    this.defaultTimeout = const Duration(seconds: 3),
    this.lateReplyWait = const Duration(seconds: 1),
  }) : gate = gate ?? BusGate() {
    _sub = _link.incoming.listen(_onBytes);
  }

  final ByteLink _link;
  final BusGate gate;
  final Duration minBusInterval;
  final Duration defaultTimeout;
  final Duration lateReplyWait;

  late final StreamSubscription<List<int>> _sub;
  final _buffer = StringBuffer();
  Completer<String>? _pending;
  Future<void> _queue = Future.value();
  DateTime? _lastBusSend;

  /// Set when a command timed out and its `>` prompt hasn't arrived yet.
  bool _lateReplyOwed = false;
  Completer<void>? _lateReply;

  /// Called with every command and reply, for logs and debugging.
  void Function(String line)? onTrace;

  Future<String> send(String command, {Duration? timeout}) {
    final (cmd, kind) = CommandPolicy.check(command);
    return _enqueue(() => _send(cmd, kind, timeout ?? defaultTimeout));
  }

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Passively listens to the bus with `ATMA` for [duration] and returns the
  /// lines seen (PLAN.md §4.1). The adapter stays silent on the bus (CAN
  /// silent monitoring is on by default). Monitoring is stopped by sending a
  /// space, which the ELM327 discards.
  Future<List<String>> monitor(Duration duration) {
    final (cmd, kind) = CommandPolicy.check('ATMA');
    return _enqueue(() => _monitor(cmd, kind, duration));
  }

  Future<List<String>> _monitor(String cmd, CommandKind kind, Duration duration) async {
    await _discardLateReply();
    await _beforeSend(cmd, kind);
    _buffer.clear();
    final completer = _pending = Completer<String>();
    onTrace?.call('> $cmd');
    await _link.write(ascii.encode('$cmd\r'));
    // The adapter may stop early by itself (e.g. BUFFER FULL).
    await Future.any([completer.future, Future<void>.delayed(duration)]);
    if (!completer.isCompleted) await _link.write(ascii.encode(' '));
    String reply;
    try {
      reply = await completer.future.timeout(defaultTimeout);
    } on TimeoutException {
      reply = _clean(_buffer.toString());
      _pending = null;
      _lateReplyOwed = true;
    }
    final lines = reply.split('\r').where((l) => l.isNotEmpty && l != 'STOPPED').toList();
    onTrace?.call('< ATMA: ${lines.length} lines');
    return lines;
  }

  Future<void> _beforeSend(String cmd, CommandKind kind) async {
    if (kind != CommandKind.bus) return;
    if (!gate.isOpen) throw BusClosedException(cmd);
    final last = _lastBusSend;
    if (last != null) {
      final wait = minBusInterval - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastBusSend = DateTime.now();
  }

  /// Waits for the prompt of a command that timed out, so its reply isn't
  /// mistaken for the next command's.
  Future<void> _discardLateReply() async {
    if (!_lateReplyOwed) return;
    final late = _lateReply = Completer<void>();
    try {
      await late.future.timeout(lateReplyWait);
    } on TimeoutException {
      onTrace?.call('< no late reply');
    }
    _lateReply = null;
    _lateReplyOwed = false;
    _buffer.clear();
  }

  Future<String> _send(String cmd, CommandKind kind, Duration timeout) async {
    await _discardLateReply();
    await _beforeSend(cmd, kind);
    _buffer.clear();
    final completer = _pending = Completer<String>();
    onTrace?.call('> $cmd');
    await _link.write(ascii.encode('$cmd\r'));
    try {
      final reply = await completer.future.timeout(timeout);
      onTrace?.call('< ${reply.replaceAll('\r', ' | ')}');
      return reply;
    } on TimeoutException {
      final partial = _buffer.toString();
      _pending = null;
      _lateReplyOwed = true;
      onTrace?.call('< TIMEOUT ($partial)');
      throw ElmTimeoutException(cmd, partial);
    }
  }

  void _onBytes(List<int> bytes) {
    for (final b in bytes) {
      // The ELM327 may emit NUL bytes after a reset; drop them.
      if (b == 0) continue;
      final ch = String.fromCharCode(b & 0x7F);
      if (ch == '>') {
        final reply = _clean(_buffer.toString());
        _buffer.clear();
        final p = _pending;
        _pending = null;
        if (p != null && !p.isCompleted) {
          p.complete(reply);
        } else if (_lateReplyOwed) {
          _lateReplyOwed = false;
          onTrace?.call('< late reply discarded (${reply.replaceAll('\r', ' | ')})');
          final late = _lateReply;
          if (late != null && !late.isCompleted) late.complete();
        }
      } else {
        _buffer.write(ch);
      }
    }
  }

  /// Normalises line endings and drops blank lines.
  static String _clean(String raw) => raw
      .replaceAll('\n', '\r')
      .split('\r')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\r');

  Future<void> close() async {
    await _sub.cancel();
    await _link.close();
  }
}
