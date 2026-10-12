import 'package:flutter/material.dart';

import '../app/app_settings.dart';
import '../app/build_info.dart';
import '../util/units.dart';
import 'settings_screen.dart';
import 'connect_controller.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.controller, required this.settings});

  final ConnectController controller;
  final AppSettings settings;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  bool _showTrace = false;

  ConnectController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, widget.settings]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Connect'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsScreen(settings: widget.settings),
              )),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (c.error != null) _ErrorBanner(c.error!),
            ...switch (c.state) {
              LinkState.idle || LinkState.scanning || LinkState.failed => _scanSection(),
              LinkState.connecting => [
                  const ListTile(
                    leading: CircularProgressIndicator(),
                    title: Text('Connecting and running adapter setup…'),
                  ),
                ],
              LinkState.connected => _connectedSection(context),
              LinkState.reconnecting => [
                  ListTile(
                    leading: const CircularProgressIndicator(),
                    title: const Text('Reconnecting to the adapter…'),
                    subtitle: Text('Attempt ${c.reconnectAttempts}. '
                        'A running recording keeps logging GPS meanwhile.'),
                  ),
                  TextButton(onPressed: c.disconnect, child: const Text('Stop reconnecting')),
                ],
            },
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(BuildInfo.label,
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ),
            if (c.trace.isNotEmpty) ...[
              const Divider(),
              SwitchListTile(
                title: const Text('Show adapter log'),
                value: _showTrace,
                onChanged: (v) => setState(() => _showTrace = v),
              ),
              if (_showTrace)
                SelectableText(
                  c.trace.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _scanSection() => [
        FilledButton.icon(
          onPressed: c.state == LinkState.scanning ? null : c.startScan,
          icon: const Icon(Icons.bluetooth_searching),
          label: Text(c.state == LinkState.scanning ? 'Scanning…' : 'Scan for adapter'),
        ),
        const SizedBox(height: 8),
        for (final r in c.scanResults)
          ListTile(
            leading: Icon(ConnectController.looksLikeAdapter(r)
                ? Icons.directions_car
                : Icons.bluetooth),
            title: Text(r.device.platformName),
            subtitle: Text('${r.device.remoteId.str}  ${r.rssi} dBm'),
            onTap: () => c.connect(r.device),
          ),
      ];

  List<Widget> _connectedSection(BuildContext context) {
    final theme = Theme.of(context);
    final carOn = c.carOn;
    return [
      Card(
        child: Column(
          children: [
            ListTile(
              title: const Text('Adapter'),
              subtitle: Text(c.adapterId ?? '?'),
            ),
            ListTile(
              title: const Text('Adapter voltage (ATRV)'),
              subtitle: Text(c.volts == null ? '?' : '${c.volts!.toStringAsFixed(1)} V'),
              trailing: Chip(
                label: Text(carOn ? 'Car on' : 'Car off'),
                backgroundColor: carOn
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            if (c.linkDescription != null)
              ListTile(
                dense: true,
                title: const Text('BLE link'),
                subtitle: Text(c.linkDescription!),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: c.busy ? null : c.checkVoltage,
            child: const Text('Re-check voltage'),
          ),
          FilledButton(
            onPressed: c.busy || !carOn ? null : c.readKnownValues,
            child: const Text('Read known values'),
          ),
          TextButton(onPressed: c.busy ? null : c.disconnect, child: const Text('Disconnect')),
        ],
      ),
      if (!carOn)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Reading values needs the car on (about 12.8 V or more). '
              'Nothing is sent on the bus while the car is off.'),
        ),
      if (c.busy) const LinearProgressIndicator(),
      const SizedBox(height: 8),
      for (final r in c.readings) _readingTile(r),
    ];
  }

  Widget _readingTile(SignalReading r) {
    final v = r.value;
    final String shown;
    if (v is double) {
      final d = toDisplay(v, r.signal.unit, widget.settings.units);
      shown = d.format(decimals: r.signal.unit == 'V' ? 2 : 1);
    } else {
      shown = v?.toString() ?? '—';
    }
    return ListTile(
      title: Text('${r.signal.name}${r.signal.verified ? '' : ' (unverified)'}'),
      subtitle: Text('${r.signal.module.name} ${r.signal.didHex}  '
          '${r.rawHex.isEmpty ? '' : 'raw ${r.rawHex}  '}${r.status}'),
      trailing: Text(shown, style: const TextStyle(fontSize: 18)),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
      ),
    );
  }
}
