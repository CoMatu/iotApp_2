import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:universal_ble/universal_ble.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _bleDevices = <BleDevice>[];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();

    UniversalBle.scanStream.listen((BleDevice device) {
      final existingDeviceIds = _bleDevices.map((e) => e.deviceId);
      if (existingDeviceIds.contains(device.deviceId)) return;
      if (device.name?.contains('HUAWEI') ?? false) {
        _bleDevices.add(device);
        setState(() {});
      }
    });
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
              ],
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
