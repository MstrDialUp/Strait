import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait/abrp/abrp_client.dart';
import 'package:strait/abrp/credentials.dart';
import 'package:strait/abrp/live_poller.dart';
import 'package:strait/abrp/telemetry.dart';
import 'package:strait/abrp/uploader.dart';
import 'package:strait/abrp/vehicle_state.dart';
import 'package:ocean_obd/elm/elm_client.dart';
import 'package:ocean_obd/platform/gps_fix.dart';
import 'package:ocean_obd/signals/signal_table.dart';
import 'package:ocean_obd/transport/elm_transport.dart';
import 'package:ocean_obd/uds/uds_client.dart';
import 'package:strait/ui/link_controller.dart';

import 'package:ocean_obd/testing/fake_elm.dart';

const creds = AbrpCredentials(apiKey: 'KEY-1234567890', token: 'TOKEN-abcdefghij');

TelemetryPoint point({double? speed = 50, bool? parked = false, bool? charging = false}) =>
    TelemetryPoint(utc: 1790000000, soc: 75.1, speed: speed, isParked: parked, isCharging: charging);

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw StateError('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('credentials', () {
    test('mask shows only the last four characters', () {
      expect(AbrpCredentials.mask('abcdefgh1234'), '••••1234');
      expect(AbrpCredentials.mask('ab'), '••••');
      expect(AbrpCredentials.mask(' '), 'not set');
    });

    test('toString never contains the secrets', () {
      expect('$creds', isNot(contains('KEY-1234567890')));
      expect('$creds', isNot(contains('TOKEN-abcdefghij')));
    });

    test('incomplete credentials', () {
      expect(const AbrpCredentials(apiKey: 'k', token: ' ').isComplete, isFalse);
    });
  });

  group('AbrpClient', () {
    late List<http.Request> requests;
    AbrpClient client(http.Response Function(http.Request) respond) {
      requests = [];
      return AbrpClient(creds, httpClient: MockClient((r) async {
        requests.add(r);
        return respond(r);
      }));
    }

    test('send: key in the header, token and tlm in the body, nothing in the URL', () async {
      final c = client((_) => http.Response('{"status":"ok","result":null}', 200));
      final r = await c.send(point());
      expect(r.ok, isTrue);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://api.iternio.com/1/tlm/send');
      expect(req.headers['Authorization'], 'APIKEY KEY-1234567890');
      expect(req.bodyFields['token'], 'TOKEN-abcdefghij');
      final tlm = jsonDecode(req.bodyFields['tlm']!) as Map<String, dynamic>;
      expect(tlm, {'utc': 1790000000, 'soc': 75.1, 'speed': 50.0, 'is_charging': 0, 'is_parked': 0});
    });

    test('bulk sends a JSON body with tlm_list', () async {
      final c = client((_) => http.Response('{"status":"ok"}', 200));
      await c.bulk([point(), point(speed: 0)]);
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      final entry = (body['data'] as List).single as Map<String, dynamic>;
      expect(entry['token'], 'TOKEN-abcdefghij');
      expect((entry['tlm_list'] as List).length, 2);
      expect(requests.single.url.path, '/1/tlm/bulk');
    });

    test('HTTP 401 points at the API key', () async {
      final r = await client((_) => http.Response('nope', 401)).send(point());
      expect(r.outcome, AbrpOutcome.http);
      expect(r.message, contains('API key'));
    });

    test('status other than ok is rejected, with the errors and no secrets', () async {
      final r = await client((_) => http.Response(
          '{"status":"error","errors":["bad token TOKEN-abcdefghij"]}', 200)).send(point());
      expect(r.outcome, AbrpOutcome.rejected);
      expect(r.message, contains('bad token'));
      expect(r.message, isNot(contains('TOKEN-abcdefghij')));
    });

    test('network failures are reported as network', () async {
      final c = AbrpClient(creds,
          httpClient: MockClient((_) async => throw const SocketException('no route')));
      expect((await c.send(point())).outcome, AbrpOutcome.network);
    });

    test('get_telemetry posts the token', () async {
      final c = client((_) => http.Response('{"status":"ok","result":{"utc":1790000000,"soc":74}}', 200));
      final r = await c.getTelemetry();
      expect(r.ok, isTrue);
      expect(requests.single.bodyFields['token'], 'TOKEN-abcdefghij');
      expect(LinkController.describeTelemetry(r.result), contains('SOC 74'));
    });
  });

  group('VehicleState', () {
    late DateTime now;
    late VehicleState v;
    setUp(() {
      now = DateTime(2026, 9, 29, 8);
      v = VehicleState(clock: () => now);
    });

    test('no car data, no point', () {
      v.updateGps(const GpsFix(lat: 1, lon: 2, speedKmh: 30));
      expect(v.snapshot(), isNull);
    });

    test('power from voltage × current; GPS fills position', () {
      v.update('voltage', 400);
      v.update('current', 50);
      v.update('speed', 80);
      v.update('soc', 75);
      v.updateGps(const GpsFix(lat: 45.5, lon: -122.6, speedKmh: 82, headingDeg: 90, altitudeM: 30));
      final p = v.snapshot()!;
      expect(p.power, closeTo(20, 1e-9));
      expect(p.speed, 80); // car speed preferred over GPS
      expect(p.lat, 45.5);
      expect(p.isParked, isFalse);
      expect(p.isCharging, isFalse);
      expect(p.isDcfc, isNull);
    });

    test('parked after 60 s stationary', () {
      v.update('soc', 75);
      v.update('speed', 0);
      expect(v.snapshot()!.isParked, isFalse);
      now = now.add(const Duration(seconds: 61));
      v.update('speed', 0);
      expect(v.snapshot()!.isParked, isTrue);
      v.update('speed', 5);
      expect(v.snapshot()!.isParked, isFalse);
    });

    test('AC and DC charging inferred from current while stationary', () {
      v.update('speed', 0);
      v.update('voltage', 400);
      v.update('current', -25); // 10 kW in
      var p = v.snapshot()!;
      expect(p.isCharging, isTrue);
      expect(p.isDcfc, isFalse);
      expect(p.isParked, isTrue);
      v.update('current', -250); // 100 kW in
      p = v.snapshot()!;
      expect(p.isDcfc, isTrue);
      expect(p.power, closeTo(-100, 1e-9));
    });

    test('regen while moving is not charging', () {
      v.update('speed', 60);
      v.update('voltage', 400);
      v.update('current', -80);
      expect(v.snapshot()!.isCharging, isFalse);
    });

    test('stale values are left out', () {
      v.update('soc', 75);
      v.update('odometer', 38800);
      now = now.add(const Duration(seconds: 20));
      v.update('speed', 10);
      final p = v.snapshot()!;
      expect(p.soc, isNull); // older than 15 s
      expect(p.odometer, 38800); // allowed 3 min
    });
  });

  group('AbrpUploader', () {
    late List<String> calls;
    late bool online;
    late AbrpUploader up;
    late TelemetryPoint? current;

    setUp(() {
      calls = [];
      online = true;
      current = point();
      final client = AbrpClient(creds, httpClient: MockClient((r) async {
        calls.add(r.url.path.split('/').last);
        if (!online) throw http.ClientException('offline');
        return http.Response('{"status":"ok"}', 200);
      }));
      up = AbrpUploader(client: client, snapshot: () => current, bufferLimit: 3, bulkBatch: 2);
    });

    test('sends the current point', () async {
      await up.tick();
      expect(calls, ['send']);
      expect(up.sent, 1);
    });

    test('skips when there is no car data', () async {
      current = null;
      await up.tick();
      expect(calls, isEmpty);
      expect(up.status, contains('Waiting'));
    });

    test('buffers while offline, capped, then flushes with bulk', () async {
      online = false;
      for (var i = 0; i < 5; i++) {
        await up.tick();
      }
      expect(up.buffer.length, 3);
      expect(up.dropped, 2);

      online = true;
      calls.clear();
      await up.tick();
      expect(calls, ['bulk', 'bulk', 'send']); // batches of 2, then the new point
      expect(up.buffer, isEmpty);
      expect(up.sent, 4);
    });

    test('5 s while driving, 30 s while parked or charging', () async {
      await up.tick();
      expect(up.interval, const Duration(seconds: 5));
      current = point(speed: 0, parked: true);
      await up.tick();
      expect(up.interval, const Duration(seconds: 30));
      current = point(speed: 0, parked: true, charging: true);
      await up.tick();
      expect(up.interval, const Duration(seconds: 30));
    });

    test('rejected points are not buffered', () async {
      final client = AbrpClient(creds,
          httpClient: MockClient((_) async => http.Response('{"status":"error","errors":"x"}', 200)));
      final u = AbrpUploader(client: client, snapshot: () => point());
      await u.tick();
      expect(u.buffer, isEmpty);
      expect(u.status, 'ABRP error');
    });
  });

  group('LivePoller', () {
    late SignalTable table;
    setUpAll(() {
      table = SignalTable.parse(File('../packages/ocean_obd/assets/signals/ocean.json').readAsStringSync());
    });

    test('polls only verified ABRP signals and feeds the vehicle state', () async {
      final fake = FakeElm(replies: {
        'ATRV': '14.1V',
        '22EFF7': '7CA0562EFF7028F', // 65.5 km/h
        '222004': '7E907622004000052D0', // 21200 → +120 A
        '222107': '7E9056221071010', // 411.2 V
        '222050': '7E9056220500300', // 76.8 %
        '223409': '7C907623409003B3350',
      });
      final uds = UdsClient(ElmClient(ElmTransport(fake, minBusInterval: Duration.zero)));
      final state = VehicleState();
      final poller = LivePoller(
        uds: () => uds,
        signals: table.signals,
        state: state,
        intervalOf: (_) => const Duration(milliseconds: 20),
      );
      expect(poller.signals.map((s) => s.abrpField).toSet(),
          {'soc', 'odometer', 'speed', 'current', 'voltage'});
      final done = poller.run();
      await waitFor(() => ['soc', 'odometer', 'speed', 'current', 'voltage'].every((f) => state.value(f) != null));
      poller.stop();
      await done;
      expect(state.value('speed'), closeTo(65.5, 1e-9));
      expect(state.value('current'), closeTo(120, 1e-9));
      expect(state.value('voltage'), closeTo(411.2, 1e-9));
      expect(state.snapshot()!.power, closeTo(49.344, 1e-6));
      // Unverified candidates never reach ABRP.
      expect(fake.sent.any((c) => c == '222089' || c == '223427'), isFalse);
    });

    test('car off: nothing on the bus, and stops after the timeout', () async {
      final fake = FakeElm(replies: {'ATRV': '12.3V'});
      final uds = UdsClient(ElmClient(ElmTransport(fake)));
      var now = DateTime(2026, 9, 29, 8);
      var timedOut = false;
      final poller = LivePoller(
        uds: () => uds,
        signals: table.signals,
        state: VehicleState(clock: () => now),
        clock: () => now,
        carOffRecheck: const Duration(milliseconds: 5),
        carOffTimeout: const Duration(minutes: 10),
      )..onCarOffTimeout = () => timedOut = true;
      final done = poller.run();
      await waitFor(() => fake.sent.where((c) => c == 'ATRV').length >= 2);
      expect(timedOut, isFalse);
      now = now.add(const Duration(minutes: 11));
      await done; // returns by itself after the timeout
      expect(timedOut, isTrue);
      expect(fake.sent.where((c) => !c.startsWith('AT')), isEmpty);
    });

    const onReplies = {
      '22EFF7': '7CA0562EFF7028F',
      '222004': '7E907622004000052D0',
      '222107': '7E9056221071010',
      '222050': '7E9056220500300',
      '223409': '7C907623409003B3350',
    };

    test('one low voltage reading does not turn the car off', () async {
      final atrv = ['14.0V', '12.6V', '13.9V'];
      var atrvCount = 0;
      final fake = FakeElm(
        replies: {...onReplies},
        handler: (cmd) {
          if (cmd != 'ATRV') return null;
          final i = atrvCount++;
          return atrv[i < atrv.length ? i : atrv.length - 1];
        },
      );
      final uds = UdsClient(ElmClient(ElmTransport(fake, minBusInterval: Duration.zero)));
      final poller = LivePoller(
        uds: () => uds,
        signals: table.signals,
        state: VehicleState(),
        intervalOf: (_) => const Duration(milliseconds: 20),
        voltageEvery: const Duration(milliseconds: 30),
        lowVoltageRecheck: const Duration(milliseconds: 5),
      );
      var everOff = false;
      poller.onUpdate = () {
        if (atrvCount > 0 && !poller.stats.carOn) everOff = true;
      };
      final done = poller.run();
      await waitFor(() => atrvCount >= 4);
      poller.stop();
      await done;
      expect(everOff, isFalse);
      expect(poller.stats.events.map((e) => e.message),
          contains(startsWith('12.6 V, below 13.0 V (1 of 3)')));
      expect(poller.stats.events.map((e) => e.message), isNot(contains('Car off')));
    });

    test('three low readings in a row turn the car off, without bus traffic', () async {
      var low = false;
      final fake = FakeElm(
        replies: {...onReplies},
        handler: (cmd) => cmd == 'ATRV' ? (low ? '12.4V' : '14.0V') : null,
      );
      final uds = UdsClient(ElmClient(ElmTransport(fake, minBusInterval: Duration.zero)));
      final poller = LivePoller(
        uds: () => uds,
        signals: table.signals,
        state: VehicleState(),
        intervalOf: (_) => const Duration(milliseconds: 20),
        voltageEvery: const Duration(milliseconds: 30),
        lowVoltageRecheck: const Duration(milliseconds: 5),
        carOffRecheck: const Duration(seconds: 30),
      );
      final done = poller.run();
      await waitFor(() => poller.stats.carOn && poller.stats.reads > 0);
      low = true;
      final atrvBefore = fake.sent.where((c) => c == 'ATRV').length;
      await waitFor(() => !poller.stats.carOn);
      final sentAfterOff = fake.sent.length;
      expect(fake.sent.where((c) => c == 'ATRV').length - atrvBefore, 3);
      expect(poller.stats.events.last.message, 'Car off');
      // Nothing more goes out while it waits.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.sent.length, sentAfterOff);
      poller.stop();
      await done;
    });

    test('a car-on reading from another screen ends the car-off wait', () async {
      var on = false;
      final fake = FakeElm(
        replies: {...onReplies},
        handler: (cmd) => cmd == 'ATRV' ? (on ? '14.0V' : '12.4V') : null,
      );
      final elm = ElmClient(ElmTransport(fake, minBusInterval: Duration.zero));
      final uds = UdsClient(elm);
      final poller = LivePoller(
        uds: () => uds,
        signals: table.signals,
        state: VehicleState(),
        intervalOf: (_) => const Duration(milliseconds: 20),
        carOffRecheck: const Duration(minutes: 1),
      );
      final done = poller.run();
      await waitFor(() => poller.stats.status.startsWith('Car off'));
      on = true;
      await elm.readVoltage(); // "Re-check voltage" on the Connect tab
      await waitFor(() => poller.stats.carOn && poller.stats.reads > 0,
          timeout: const Duration(seconds: 5));
      poller.stop();
      await done;
    });

    test('a gate closed elsewhere is re-checked, not taken as car off', () async {
      final fake = FakeElm(replies: {'ATRV': '14.0V', ...onReplies});
      final elm = ElmClient(ElmTransport(fake, minBusInterval: Duration.zero));
      final uds = UdsClient(elm);
      final poller = LivePoller(
        uds: () => uds,
        signals: table.signals,
        state: VehicleState(),
        intervalOf: (_) => const Duration(milliseconds: 20),
      );
      final done = poller.run();
      await waitFor(() => poller.stats.reads > 0);
      final atrv = fake.sent.where((c) => c == 'ATRV').length;
      elm.transport.gate.close();
      final reads = poller.stats.reads;
      await waitFor(() => poller.stats.reads > reads + 2);
      expect(poller.stats.carOn, isTrue);
      expect(fake.sent.where((c) => c == 'ATRV').length, greaterThan(atrv));
      expect(poller.stats.events.map((e) => e.message), isNot(contains('Car off')));
      poller.stop();
      await done;
    });
  });
}
