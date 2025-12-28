import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '蓝牙配网',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      home: const BleWifiProvisionPage(),
    );
  }
}

class BleWifiProvisionPage extends StatefulWidget {
  const BleWifiProvisionPage({super.key});

  @override
  State<BleWifiProvisionPage> createState() => _BleWifiProvisionPageState();
}

class _BleWifiProvisionPageState extends State<BleWifiProvisionPage> {
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  StreamSubscription<bool>? _isScanningSub;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;

  final Map<DeviceIdentifier, ScanResult> _resultsById = {};
  bool _bleInitialized = false;
  bool _isScanning = false;
  BluetoothAdapterState? _adapterState;

  BluetoothDevice? _connectedDevice;
  List<_WritableCharacteristic> _writableCharacteristics = [];
  _WritableCharacteristic? _selectedCharacteristic;

  bool _appendNewline = true;
  bool _useWriteWithoutResponse = false;
  String _statusText = '';

  @override
  void dispose() {
    _scanResultsSub?.cancel();
    _isScanningSub?.cancel();
    _adapterStateSub?.cancel();
    _connectedDevice?.disconnect();
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _initBleIfNeeded() async {
    if (_bleInitialized) return;
    if (!await FlutterBluePlus.isSupported) {
      setState(() {
        _statusText = '当前设备不支持蓝牙功能';
      });
      return;
    }

    _adapterStateSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() {
        _adapterState = state;
      });
    });

    _isScanningSub = FlutterBluePlus.isScanning.listen((isScanning) {
      if (!mounted) return;
      setState(() {
        _isScanning = isScanning;
      });
    });

    _scanResultsSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          _resultsById[r.device.remoteId] = r;
        }
      });
    });

    setState(() {
      _bleInitialized = true;
    });
  }

  Future<bool> _requestPermissions() async {
    if (kIsWeb) return true;

    final TargetPlatform p = defaultTargetPlatform;
    if (p == TargetPlatform.android) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final allGranted = statuses.values.every((s) => s.isGranted);
      if (!allGranted) {
        final permanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
        if (permanentlyDenied) {
          await openAppSettings();
        }
      }
      return allGranted;
    }

    if (p == TargetPlatform.iOS) {
      final status = await Permission.bluetooth.request();
      if (!status.isGranted && status.isPermanentlyDenied) {
        await openAppSettings();
      }
      return status.isGranted;
    }

    return true;
  }

  Future<void> _startScan() async {
    await _initBleIfNeeded();
    if (!_bleInitialized) return;

    final ok = await _requestPermissions();
    if (!ok) {
      setState(() {
        _statusText = '缺少权限，无法扫描蓝牙设备';
      });
      return;
    }

    if (_adapterState != null && _adapterState != BluetoothAdapterState.on) {
      setState(() {
        _statusText = '请先打开手机蓝牙';
      });
      return;
    }

    await _connectedDevice?.disconnect();
    setState(() {
      _connectedDevice = null;
      _writableCharacteristics = [];
      _selectedCharacteristic = null;
      _resultsById.clear();
      _statusText = '';
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
  }

  Future<void> _stopScan() async {
    if (!_bleInitialized) return;
    await FlutterBluePlus.stopScan();
  }

  Future<void> _connect(ScanResult r) async {
    await _stopScan();

    setState(() {
      _statusText = '正在连接：${_deviceLabel(r)}';
    });

    final device = r.device;
    try {
      await _connectedDevice?.disconnect();
      await device.connect(timeout: const Duration(seconds: 15), license: License.free);
      final services = await device.discoverServices();
      final chars = <_WritableCharacteristic>[];
      for (final s in services) {
        for (final c in s.characteristics) {
          final canWrite = c.properties.write || c.properties.writeWithoutResponse;
          if (!canWrite) continue;
          chars.add(_WritableCharacteristic(
            device: device,
            serviceUuid: s.uuid,
            characteristic: c,
          ));
        }
      }

      setState(() {
        _connectedDevice = device;
        _writableCharacteristics = chars;
        _selectedCharacteristic = chars.isEmpty ? null : chars.first;
        _statusText = chars.isEmpty ? '连接成功，但未发现可写特征' : '连接成功';
      });
    } catch (e) {
      setState(() {
        _connectedDevice = null;
        _writableCharacteristics = [];
        _selectedCharacteristic = null;
        _statusText = '连接失败：$e';
      });
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _disconnect() async {
    final d = _connectedDevice;
    if (d == null) return;
    try {
      await d.disconnect();
    } finally {
      if (!mounted) return;
      setState(() {
        _connectedDevice = null;
        _writableCharacteristics = [];
        _selectedCharacteristic = null;
        _statusText = '已断开连接';
      });
    }
  }

  Future<void> _sendWifiConfig() async {
    final target = _selectedCharacteristic;
    if (target == null) {
      setState(() {
        _statusText = '请先选择可写特征';
      });
      return;
    }

    final ssid = _ssidController.text.trim();
    final password = _passwordController.text;
    if (ssid.isEmpty) {
      setState(() {
        _statusText = 'SSID 不能为空';
      });
      return;
    }

    final payload = jsonEncode({
      'ssid': ssid,
      'password': password,
    });
    final text = _appendNewline ? '$payload\n' : payload;
    final bytes = utf8.encode(text);

    final canWriteWithoutResponse = target.characteristic.properties.writeWithoutResponse;
    final useWithoutResponse = _useWriteWithoutResponse && canWriteWithoutResponse;

    try {
      await target.characteristic.write(
        bytes,
        withoutResponse: useWithoutResponse,
      );
      setState(() {
        _statusText = '已发送：$payload';
      });
    } catch (e) {
      setState(() {
        _statusText = '发送失败：$e';
      });
    }
  }

  String _deviceLabel(ScanResult r) {
    final name = r.device.platformName.trim().isEmpty ? '未命名设备' : r.device.platformName;
    return '$name (${r.device.remoteId.str})';
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connectedDevice != null;
    final results = _resultsById.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('蓝牙配网'),
        actions: [
          IconButton(
            onPressed: _isScanning ? _stopScan : _startScan,
            icon: Icon(_isScanning ? Icons.stop : Icons.search),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(
              bleInitialized: _bleInitialized,
              isScanning: _isScanning,
              adapterState: _adapterState,
              statusText: _statusText,
              onInit: _initBleIfNeeded,
              onScan: _startScan,
            ),
            const SizedBox(height: 12),
            _SectionTitle(title: connected ? '已连接设备' : '扫描到的设备'),
            const SizedBox(height: 8),
            if (!connected)
              ...results.map((r) {
                return Card(
                  child: ListTile(
                    title: Text(_deviceLabel(r)),
                    subtitle: Text('RSSI: ${r.rssi}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _connect(r),
                  ),
                );
              }),
            if (connected) ...[
              Card(
                child: ListTile(
                  title: Text(_connectedDevice!.platformName.trim().isEmpty
                      ? '未命名设备'
                      : _connectedDevice!.platformName),
                  subtitle: Text(_connectedDevice!.remoteId.str),
                  trailing: TextButton(
                    onPressed: _disconnect,
                    child: const Text('断开'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _SectionTitle(title: '选择可写特征'),
              const SizedBox(height: 8),
              _CharacteristicPicker(
                items: _writableCharacteristics,
                selected: _selectedCharacteristic,
                onChanged: (v) => setState(() => _selectedCharacteristic = v),
              ),
              const SizedBox(height: 12),
              _SectionTitle(title: 'WiFi 配置'),
              const SizedBox(height: 8),
              TextField(
                controller: _ssidController,
                decoration: const InputDecoration(
                  labelText: 'SSID',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码（可为空）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                value: _appendNewline,
                onChanged: (v) => setState(() => _appendNewline = v),
                title: const Text('末尾追加换行符'),
              ),
              SwitchListTile(
                value: _useWriteWithoutResponse,
                onChanged: (v) => setState(() => _useWriteWithoutResponse = v),
                title: const Text('优先使用 Write Without Response'),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _sendWifiConfig,
                child: const Text('发送 WiFi 配置'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WritableCharacteristic {
  _WritableCharacteristic({
    required this.device,
    required this.serviceUuid,
    required this.characteristic,
  });

  final BluetoothDevice device;
  final Guid serviceUuid;
  final BluetoothCharacteristic characteristic;

  String label() {
    final c = characteristic;
    final w = c.properties.write;
    final wnr = c.properties.writeWithoutResponse;
    final props = <String>[
      if (w) 'write',
      if (wnr) 'writeNoRsp',
    ].join(',');
    return '${serviceUuid.str} / ${c.uuid.str} ($props)';
  }
}

class _CharacteristicPicker extends StatelessWidget {
  const _CharacteristicPicker({
    required this.items,
    required this.selected,
    required this.onChanged,
  });

  final List<_WritableCharacteristic> items;
  final _WritableCharacteristic? selected;
  final ValueChanged<_WritableCharacteristic?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text('未发现可写特征');
    }
    return DropdownButtonFormField<_WritableCharacteristic>(
      value: selected,
      items: items
          .map((e) => DropdownMenuItem<_WritableCharacteristic>(
                value: e,
                child: Text(e.label(), overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: onChanged,
      decoration: const InputDecoration(border: OutlineInputBorder()),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.bleInitialized,
    required this.isScanning,
    required this.adapterState,
    required this.statusText,
    required this.onInit,
    required this.onScan,
  });

  final bool bleInitialized;
  final bool isScanning;
  final BluetoothAdapterState? adapterState;
  final String statusText;
  final Future<void> Function() onInit;
  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    final stateText = adapterState == null ? '未知' : adapterState!.name;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '蓝牙状态：$stateText',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: bleInitialized ? null : onInit,
                  child: const Text('初始化'),
                ),
                const SizedBox(width: 6),
                FilledButton.tonal(
                  onPressed: isScanning ? null : onScan,
                  child: const Text('扫描'),
                ),
              ],
            ),
            if (statusText.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(statusText),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleMedium);
  }
}
