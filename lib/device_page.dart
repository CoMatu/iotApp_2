import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

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

  @override
  void initState() {
    super.initState();
    _loadPairedState();
  }

  Future<void> _loadPairedState() async {
    try {
      final paired = await UniversalBle.isPaired(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _isPaired = paired;
      });
    } catch (_) {
      // If the platform requires pairingCommand for status, ignore silently.
    }
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
      await UniversalBle.pair(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _isPaired = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pairing successful')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pairing failed: $e')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unpair successful')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unpair failed: $e')),
      );
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
                _isPaired == true ? 'Paired' : 'Not paired',
                style: Theme.of(context).textTheme.bodyMedium,
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
                      : (_isPaired == true ? 'Paired' : 'Pair'),
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
