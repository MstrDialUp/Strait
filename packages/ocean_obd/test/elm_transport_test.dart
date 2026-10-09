import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_obd/elm/elm_client.dart';
import 'package:ocean_obd/transport/bus_gate.dart';
import 'package:ocean_obd/transport/command_policy.dart';
import 'package:ocean_obd/transport/elm_transport.dart';

import 'package:ocean_obd/testing/fake_elm.dart';

void main() {
  group('ElmTransport', () {
    test('returns the reply up to the prompt across chunked notifications', () async {
      final fake = FakeElm(replies: {'ATI': 'ELM327 v2.2'}, chunkSize: 3);
      final t = ElmTransport(fake);
      expect(await t.send('ATI'), 'ELM327 v2.2');
    });

    test('serialises concurrent commands', () async {
      final fake = FakeElm(replies: {'ATI': 'ELM327 v2.2', 'ATRV': '12.4V'});
      final t = ElmTransport(fake);
      final results = await Future.wait([t.send('ATI'), t.send('ATRV'), t.send('ATE0')]);
      expect(results, ['ELM327 v2.2', '12.4V', 'OK']);
      expect(fake.sent, ['ATI', 'ATRV', 'ATE0']);
    });

    test('rejects forbidden commands before writing anything', () async {
      final fake = FakeElm();
      final t = ElmTransport(fake);
      expect(() => t.send('14FFFFFF'), throwsA(isA<ForbiddenCommandException>()));
      expect(fake.sent, isEmpty);
    });

    test('blocks bus traffic until ATRV shows the car on', () async {
      final fake = FakeElm(replies: {'ATRV': '12.3V', '222050': '7E9056220500384'});
      final t = ElmTransport(fake);
      final elm = ElmClient(t);

      await expectLater(t.send('222050'), throwsA(isA<BusClosedException>()));
      expect(await elm.readVoltage(), 12.3);
      await expectLater(t.send('222050'), throwsA(isA<BusClosedException>()));
      expect(fake.sent, ['ATRV']);

      fake.replies['ATRV'] = '14.1V';
      expect(await elm.readVoltage(), 14.1);
      expect(await t.send('222050'), '7E9056220500384');
    });

    test('times out without a prompt', () async {
      final fake = FakeElm()..responsive = false;
      final t = ElmTransport(fake,
          defaultTimeout: const Duration(milliseconds: 50),
          lateReplyWait: const Duration(milliseconds: 20));
      await expectLater(t.send('ATI'), throwsA(isA<ElmTimeoutException>()));
      // The queue keeps working afterwards.
      fake.responsive = true;
      expect(await t.send('ATE0'), 'OK');
    });

    test('a late reply after a timeout is not taken as the next reply', () async {
      final fake = FakeElm(replies: {'ATRV': '14.1V', '222050': '7E9056220500384'});
      fake.delays['222050'] = const Duration(milliseconds: 80);
      final t = ElmTransport(fake,
          minBusInterval: Duration.zero,
          defaultTimeout: const Duration(milliseconds: 50),
          lateReplyWait: const Duration(milliseconds: 200));
      final elm = ElmClient(t);
      expect(await elm.readVoltage(), 14.1);
      await expectLater(t.send('222050'), throwsA(isA<ElmTimeoutException>()));
      // The bus reply arrives after the timeout; ATRV must still get its own.
      expect(await elm.readVoltage(), 14.1);
      fake.delays.clear();
      expect(await t.send('222050'), '7E9056220500384');
      expect(await t.send('ATI'), 'OK');
    });

    test('a late reply that arrives before the next command is dropped', () async {
      final fake = FakeElm(replies: {'ATI': 'ELM327 v2.2', 'ATRV': '13.9V'});
      fake.delays['ATI'] = const Duration(milliseconds: 60);
      final t = ElmTransport(fake,
          defaultTimeout: const Duration(milliseconds: 30),
          lateReplyWait: const Duration(seconds: 5));
      await expectLater(t.send('ATI'), throwsA(isA<ElmTimeoutException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final sw = Stopwatch()..start();
      expect(await t.send('ATRV'), '13.9V');
      // Nothing left to wait for, so no lateReplyWait delay.
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('spaces bus requests at least minBusInterval apart', () async {
      final fake = FakeElm(replies: {'ATRV': '14.0V'}, defaultReply: 'NO DATA');
      final t = ElmTransport(fake, minBusInterval: const Duration(milliseconds: 40));
      await ElmClient(t).readVoltage();
      final sw = Stopwatch()..start();
      await t.send('222050');
      await t.send('222051');
      await t.send('222052');
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(80));
    });
  });

  group('BusGate', () {
    test('closes when the reading is stale', () {
      var now = DateTime(2026, 1, 1, 12);
      final g = BusGate(clock: () => now, maxReadingAge: const Duration(seconds: 90));
      g.recordVoltage(13.8);
      expect(g.isOpen, isTrue);
      now = now.add(const Duration(seconds: 91));
      expect(g.isOpen, isFalse);
    });

    test('threshold is inclusive at 13.0 V', () {
      final g = BusGate()..recordVoltage(13.0);
      expect(g.isOpen, isTrue);
      g.recordVoltage(12.99);
      expect(g.isOpen, isFalse);
    });

    test('close() forces the gate shut', () {
      final g = BusGate()..recordVoltage(14);
      g.close();
      expect(g.isOpen, isFalse);
    });
  });

  group('ElmClient', () {
    test('parses ATRV replies', () {
      expect(ElmClient.parseVoltage('12.6V'), 12.6);
      expect(ElmClient.parseVoltage(' 14.2 V'), 14.2);
      expect(ElmClient.parseVoltage('?'), isNull);
    });

    test('initialize sends the setup sequence and nothing on the bus', () async {
      final fake = FakeElm(replies: {'ATZ': 'ELM327 v2.2'});
      await ElmClient(ElmTransport(fake)).initialize();
      expect(fake.sent, ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH1', 'ATSP6', 'ATFCSD300000']);
      for (final c in fake.sent) {
        expect(CommandPolicy.check(c).$2, CommandKind.adapterLocal);
      }
    });

    test('initialize fails if a setup command is rejected', () async {
      final fake = FakeElm(replies: {'ATSP6': '?'});
      await expectLater(
          ElmClient(ElmTransport(fake)).initialize(), throwsA(isA<ElmSetupException>()));
    });
  });
}
