import 'dart:async';

import 'package:flutter/material.dart';

import '../abrp/credentials.dart';
import '../abrp/live_poller.dart';
import 'package:ocean_obd/app/app_settings.dart';
import 'package:ocean_obd/util/units.dart';
import 'link_controller.dart';

/// The ABRP tab (PLAN.md §5.2): the user's own API key and token, the live
/// link, and what was last sent.
class LinkScreen extends StatefulWidget {
  const LinkScreen({super.key, required this.controller, required this.settings});

  final LinkController controller;
  final AppSettings settings;

  @override
  State<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<LinkScreen> {
  final _apiKey = TextEditingController();
  final _token = TextEditingController();
  bool _editing = false;
  bool _show = false;
  Timer? _ticker;

  LinkController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (c.linking && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _apiKey.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await c.saveCredentials(apiKey: _apiKey.text, token: _token.text);
    if (c.hasCredentials) {
      _apiKey.clear();
      _token.clear();
      setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.connect, widget.settings]),
      builder: (context, _) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('ABRP')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (c.error != null)
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(padding: const EdgeInsets.all(12), child: Text(c.error!)),
                ),
              _credentialsCard(context),
              const SizedBox(height: 12),
              if (c.hasCredentials) _linkCard(context),
            ],
          ),
        );
      },
    );
  }

  Widget _credentialsCard(BuildContext context) {
    final creds = c.credentials;
    if (c.hasCredentials && !_editing) {
      return Card(
        child: Column(children: [
          ListTile(
            title: const Text('ABRP API key'),
            subtitle: Text(AbrpCredentials.mask(creds!.apiKey)),
          ),
          ListTile(
            title: const Text('ABRP token'),
            subtitle: Text(AbrpCredentials.mask(creds.token)),
          ),
          OverflowBar(children: [
            TextButton(
              onPressed: c.linking ? null : () => setState(() => _editing = true),
              child: const Text('Change'),
            ),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Remove ABRP key and token?'),
                    content: const Text('They are deleted from this phone. '
                        'You can enter them again at any time.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok == true) await c.clearCredentials();
              },
              child: const Text('Remove'),
            ),
          ]),
        ]),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your ABRP account', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Both come from your own ABRP account and are stored only on this phone.\n'
              '• API key: ABRP → API keys → telemetry. Allow posting (and reading, '
              'for "Check ABRP").\n'
              '• Token: ABRP → Settings → your Ocean → Modify connections → '
              'Generic → Link.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKey,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'API key'),
            ),
            TextField(
              controller: _token,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Token'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show while typing'),
              value: _show,
              onChanged: (v) => setState(() => _show = v ?? false),
            ),
            OverflowBar(children: [
              if (c.hasCredentials)
                TextButton(
                    onPressed: () => setState(() => _editing = false),
                    child: const Text('Cancel')),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _linkCard(BuildContext context) {
    final poller = c.pollerStats;
    final up = c.uploader;
    final units = widget.settings.units;
    final v = c.vehicle;
    final connected = c.connect.uds != null;
    String show(String field, String unit, {int decimals = 1}) {
      final value = v?.value(field);
      return value == null ? '—' : toDisplay(value, unit, units).format(decimals: decimals);
    }

    final point = up?.lastPoint;
    final last = up?.lastSuccessAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: c.linking ? c.stop : (connected ? c.start : null),
              child: Text(c.linking ? 'Stop sending to ABRP' : 'Start sending to ABRP'),
            ),
            if (!connected && !c.linking)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Connect to the adapter first (Connect tab).'),
              ),
            if (c.linking) ...[
              const SizedBox(height: 8),
              _row('Car', poller == null
                  ? '—'
                  : '${poller.carOn ? 'on' : 'off'}'
                      '${poller.volts == null ? '' : ' (${poller.volts!.toStringAsFixed(1)} V)'}'
                      ' · ${poller.status}'),
              _row('ABRP', '${up?.status ?? '—'}'
                  '${last == null ? '' : ' · last OK ${DateTime.now().difference(last).inSeconds} s ago'}'),
              _row('Sent', '${up?.sent ?? 0} points'
                  '${(up?.buffer.length ?? 0) > 0 ? ' · ${up!.buffer.length} waiting' : ''}'
                  '${(up?.dropped ?? 0) > 0 ? ' · ${up!.dropped} dropped' : ''}'),
              if (up?.lastResult != null && !up!.lastResult!.ok)
                _row('Last error', up.lastResult!.message),
              const Divider(),
              _row('SOC', show('soc', '%')),
              _row('Speed', show('speed', 'km/h', decimals: 0)),
              _row('Power', point?.power == null ? '—' : '${point!.power!.toStringAsFixed(1)} kW'),
              _row('Voltage / current', '${show('voltage', 'V')} / ${show('current', 'A')}'),
              _row('Odometer', show('odometer', 'km', decimals: 0)),
              _row('State', point == null
                  ? '—'
                  : [
                      if (point.isParked == true) 'parked',
                      if (point.isCharging == true) point.isDcfc == true ? 'DC charging' : 'charging',
                      if (point.isParked != true && point.isCharging != true) 'driving',
                    ].join(', ')),
                          if (poller != null && poller.events.isNotEmpty) _eventsTile(poller.events),
            ],
            const Divider(),
            OutlinedButton(
              onPressed: c.checking ? null : c.checkAbrp,
              child: Text(c.checking ? 'Checking…' : 'Check what ABRP received'),
            ),
            if (c.checkResult != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(c.checkResult!)),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('ABRP processes data with about a minute of delay, so new points '
                  'show up after a minute or two.'),
            ),
          ],
        ),
      ),
    );
  }

  /// The link's recent decisions, newest first, to see why it called the
  /// car off.
  Widget _eventsTile(List<LinkEvent> events) {
    String time(DateTime t) => [t.hour, t.minute, t.second].map((n) => '$n'.padLeft(2, '0')).join(':');
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('Link events (${events.length})'),
      children: [
        for (final e in events.reversed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 80, child: Text(time(e.at))),
              Expanded(child: Text(e.message)),
            ]),
          ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(label)),
          Expanded(child: Text(value)),
        ]),
      );
}
