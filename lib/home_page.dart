import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:iot_monitor_2/huawei/huawei_pairing_manager.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _bleDevices = <BleDevice>[];
  final HuaweiBand10PairingManager _pairingManager =
      HuaweiBand10PairingManager();
  bool _isScanning = false;
  bool _isRestoringSaved = false;
  HuaweiStoredSession? _lastStoredSession;

  @override
  void initState() {
    super.initState();
    _loadStoredSession();

    UniversalBle.scanStream.listen((BleDevice device) {
      final existingDeviceIds = _bleDevices.map((e) => e.deviceId);
      if (existingDeviceIds.contains(device.deviceId)) return;
      if (device.name?.contains('HUAWEI') ?? false) {
        _bleDevices.add(device);
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _pairingManager.dispose();
    super.dispose();
  }

  Future<void> _loadStoredSession() async {
    final states = await _pairingManager.loadAllPairedDeviceStates();
    if (!mounted) return;
    setState(() {
      _lastStoredSession = states.isNotEmpty ? states.first : null;
    });
  }

  Future<void> _restoreLastConnection() async {
    final last = _lastStoredSession;
    if (last == null || _isRestoringSaved || _isScanning) return;
    setState(() => _isRestoringSaved = true);
    try {
      try {
        await UniversalBle.stopScan();
      } catch (_) {}

      await _pairingManager.restoreConnection(deviceId: last.deviceId);
      await _pairingManager.startLiveMetrics(last.deviceId);
      await _loadStoredSession();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection restored: ${last.deviceId}')),
      );
    } catch (e) {
      await _pairingManager.stopLiveMetrics();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    } finally {
      if (mounted) {
        setState(() => _isRestoringSaved = false);
      }
    }
  }

  void _scanDevices() {
    if (_isScanning) {
      UniversalBle.stopScan();
      setState(() {
        _isScanning = false;
      });
    } else {
      UniversalBle.startScan();
      setState(() {
        _isScanning = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_isScanning) LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 16.0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              spacing: 8,
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    ),
                    onPressed: () {
                      _scanDevices();
                    },
                    child: Text(_isScanning ? 'Stop scanning' : 'Scan devices'),
                  ),
                ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_isRestoringSaved || _lastStoredSession == null)
                        ? null
                        : _restoreLastConnection,
                    icon: const Icon(Icons.refresh),
                    label: Text(_isRestoringSaved ? 'Restoring...' : 'Restore'),
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: () async {
              // Get already connected devices.
              // You can set `withServices` to narrow down the results.
              // On `Apple`, `withServices` is required to get any connected devices. If not passed, several [18XX] generic services will be set by default.
              List<BleDevice> devices = await UniversalBle.getSystemDevices();
              print(devices);
            },
            child: Text('Show system devices'),
          ),

          if (_lastStoredSession != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Сохраненное устройство: ${_lastStoredSession!.deviceId}',
                ),
              ),
            ),
          StreamBuilder<HuaweiLiveMetrics>(
            stream: _pairingManager.liveMetricsStream,
            initialData: _pairingManager.latestLiveMetrics,
            builder: (context, snapshot) {
              final metrics = snapshot.data ?? HuaweiLiveMetrics.disconnected();
              final isConnected = metrics.isConnected;
              final targetDeviceId =
                  metrics.deviceId ?? _lastStoredSession?.deviceId;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 10.0, 16.0, 4.0),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10.0),
                    child: Row(
                      children: [
                        Icon(
                          isConnected
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth_disabled,
                          color: isConnected
                              ? Colors.green
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        /*    Expanded(
                          child: Text(
                            isConnected
                                ? 'Устройство подключено'
                                : 'Устройство не подключено',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ), */
                        OutlinedButton.icon(
                          onPressed: (targetDeviceId == null)
                              ? null
                              : () => context.push('/device/$targetDeviceId'),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Открыть устройство'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          StreamBuilder<HuaweiLiveMetrics>(
            stream: _pairingManager.liveMetricsStream,
            initialData: _pairingManager.latestLiveMetrics,
            builder: (context, snapshot) {
              final metrics = snapshot.data ?? HuaweiLiveMetrics.disconnected();
              if (!metrics.isConnected) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 8.0),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: _MetricTile(
                            title: 'Пульс',
                            value: metrics.heartRate == null
                                ? 'нет данных'
                                : '${metrics.heartRate} bpm',
                            icon: Icons.favorite,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MetricTile(
                            title: 'Шаги',
                            value: metrics.steps == null
                                ? 'нет данных'
                                : '${metrics.steps}',
                            icon: Icons.directions_walk,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _bleDevices.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    onTap: () async {
                      // _bleDevices[index].pair();
                      final deviceId = _bleDevices[index].deviceId.toString();
                      // Используем `push`, чтобы маршрут устройства добавлялся в историю,
                      // и системная кнопка "Назад" возвращала на предыдущий экран.
                      context.push('/device/$deviceId');
                    },
                    title: Text(_bleDevices[index].name ?? ''),
                    subtitle: Text(_bleDevices[index].deviceId.toString()),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(height: 8),
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
