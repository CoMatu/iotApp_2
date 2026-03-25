import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:iot_monitor_2/huawei/huawei_pairing_manager.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  bool _isPairing = false;
  bool _isUnpairing = false;
  bool? _isPaired;
  String? _productModel;
  int? _batteryLevel;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _pair() async {
    if (_isPairing) return;
    setState(() => _isPairing = true);
    try {
      // Stop scanning before pairing/connecting (library recommendation).
      try {
        await UniversalBle.stopScan();
      } catch (_) {
        // Ignore stop scan errors (e.g. scan already stopped).
      }

      final manager = HuaweiBand10PairingManager();
      final result = await manager.pairAndInitialize(deviceId: widget.deviceId);
      if (!mounted) return;
      setState(() {
        // pairing считаем успешным только при наличии критичных данных.
        // Для UI считаем "готово", если удалось прочитать батарею.
        _isPaired = (result.batteryLevel != null);
        _productModel = result.productModel;
        _batteryLevel = result.batteryLevel;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device is ready for daily use')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Pairing failed: $e')));
    } finally {
      if (!mounted) return;
      setState(() => _isPairing = false);
    }
  }

  Future<void> _unpair() async {
    if (_isUnpairing || _isPairing) return;
    setState(() => _isUnpairing = true);
    try {
      await UniversalBle.unpair(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _isPaired = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unpair successful')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unpair failed: $e')));
    } finally {
      if (!mounted) return;
      setState(() => _isUnpairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceId = widget.deviceId;
    return Scaffold(
      appBar: AppBar(title: const Text('Device')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onPrimary,
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 1.0,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  'Device ID: $deviceId',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
          ),
          if (_isPaired != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                _isPaired == true
                    ? 'Готово для повседневного использования'
                    : 'Не готово',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (_isPaired == true &&
              (_productModel != null || _batteryLevel != null))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                children: [
                  if (_productModel != null)
                    Text(
                      'Модель: $_productModel',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  if (_batteryLevel != null)
                    Text(
                      'Батарея: $_batteryLevel%',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: Icon(
                  _isPaired == true ? Icons.bluetooth_connected : Icons.link,
                ),
                label: Text(
                  _isPairing
                      ? 'Pairing...'
                      : (_isPaired == true ? 'Готово' : 'Pair'),
                ),
                onPressed: (_isPairing || _isUnpairing || _isPaired == true)
                    ? null
                    : _pair,
              ),
            ),
          ),
          if (_isPaired == true)
            Padding(
              padding: const EdgeInsets.only(
                left: 16.0,
                right: 16.0,
                bottom: 24.0,
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.bluetooth_disabled),
                  label: Text(_isUnpairing ? 'Unpairing...' : 'Unpair'),
                  onPressed: (_isPairing || _isUnpairing || _isPaired != true)
                      ? null
                      : _unpair,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
