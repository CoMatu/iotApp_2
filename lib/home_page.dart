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
  final HuaweiBand10PairingManager _pairingManager = HuaweiBand10PairingManager();
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
      await _loadStoredSession();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection restored: ${last.deviceId}')),
      );
      context.push('/device/${last.deviceId}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
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
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                  onPressed: () {
                    _scanDevices();
                  },
                  child: Text(_isScanning ? 'Stop scanning' : 'Scan devices'),
                ),
                OutlinedButton.icon(
                  onPressed: (_isRestoringSaved || _lastStoredSession == null)
                      ? null
                      : _restoreLastConnection,
                  icon: const Icon(Icons.refresh),
                  label: Text(_isRestoringSaved ? 'Restoring...' : 'Восстановить'),
                ),
              ],
            ),
          ),
          if (_lastStoredSession != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Сохраненное устройство: ${_lastStoredSession!.deviceId}'),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _bleDevices.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    onTap: () {
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
