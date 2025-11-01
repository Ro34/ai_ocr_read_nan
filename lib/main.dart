import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'camera_capture_page.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    // 多巴胺风格：更鲜艳的配色（主色：亮粉；辅色：电光青；三级：明黄）
      const seed = Color(0xFF10B981); // Emerald 500
      final baseLight = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light);
      final lightScheme = baseLight.copyWith(
        secondary: const Color(0xFF06B6D4), // Cyan 400
        tertiary: const Color(0xFF84CC16),  // Lime 500
      );
      final baseDark = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
      final darkScheme = baseDark.copyWith(
        secondary: const Color(0xFF06B6D4),
        tertiary: const Color(0xFF84CC16),
      );
    return MaterialApp(
      title: 'AI OCR Read',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightScheme,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            side: const BorderSide(width: 1.2),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        cardTheme: CardThemeData(
          clipBehavior: Clip.antiAlias,
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: EdgeInsets.zero,
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            side: const BorderSide(width: 1.2),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        cardTheme: CardThemeData(
          clipBehavior: Clip.antiAlias,
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: EdgeInsets.zero,
        ),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, showCloseIcon: true),
      ),
      themeMode: ThemeMode.system,
      home: const MyHomePage(title: '拍照预览'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  XFile? _photo;
  bool _isAnalyzing = false;
  String? _resultText;
  static const MethodChannel _nan = MethodChannel('ai_ocr_read/nan');
  static const EventChannel _nanEvents = EventChannel('ai_ocr_read/nan_events');
  bool _nanReady = false;
  String _nanStatus = '未启动';
  int _nanPeers = 0;
  final List<String> _nanLogs = [];
  StreamSubscription? _nanSub;
  String? _deviceId;
  int _msgSeq = 0;
  bool _nanStarting = false;
  String? _roomCode; // 可配置的房间码
  final TextEditingController _roomController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initDeviceId();
    _initRoomCode();
    _nanSub = _nanEvents.receiveBroadcastStream().listen((event) {
      if (!mounted) return;
      try {
        final map = Map<String, dynamic>.from(event as Map);
        final type = map['type'] as String?;
        switch (type) {
          case 'attached':
            setState(() => _nanStatus = '已附着');
            break;
          case 'publish':
            if (map['state'] == 'started') {
              setState(() => _nanStatus = '已发布');
            } else if (map['state'] == 'terminated') {
              setState(() => _nanStatus = '发布结束');
            }
            break;
          case 'subscribe':
            if (map['state'] == 'started') {
              setState(() {
                _nanStatus = '已订阅';
                _nanReady = true;
              });
            } else if (map['state'] == 'terminated') {
              setState(() => _nanStatus = '订阅结束');
            }
            break;
          case 'discovered':
            setState(() => _nanPeers = (map['peers'] as int?) ?? _nanPeers);
            break;
          case 'send':
            final via = map['via'];
            final result = map['result'];
            final id = map['id'];
            _appendNanLog('send[$via] #$id => $result');
            break;
          case 'broadcast':
            final count = map['count'];
            _appendNanLog('broadcast -> $count peers');
            break;
          case 'message':
            final via = map['via'];
            final text = map['text'];
            try {
              final m = jsonDecode(text);
              if (m is Map && m['sender'] != null && m['seq'] != null) {
                _appendNanLog('recv[$via] from ${m['sender']}#${m['seq']}: ${m['body']}');
                break;
              }
            } catch (_) {}
            _appendNanLog('recv[$via]: $text');
            break;
          case 'released':
            setState(() {
              _nanStatus = '已释放';
              _nanReady = false;
              _nanPeers = 0;
            });
            break;
        }
      } catch (_) {
        // ignore
      }
    });
  }

  void _appendNanLog(String line) {
    setState(() {
      _nanLogs.add(line);
      if (_nanLogs.length > 100) {
        _nanLogs.removeAt(0);
      }
    });
  }

  @override
  void dispose() {
    _nanSub?.cancel();
    _roomController.dispose();
    super.dispose();
  }

  Future<void> _initDeviceId() async {
    try {
      final sp = await SharedPreferences.getInstance();
      var id = sp.getString('device_id');
      if (id == null || id.isEmpty) {
        id = _genId();
        await sp.setString('device_id', id);
      }
      if (mounted) setState(() => _deviceId = id);
    } catch (_) {
      // 忽略本地存储异常
      if (mounted) setState(() => _deviceId = 'unknown');
    }
  }

  String _genId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = (now ^ (now >> 7) ^ (now << 3)) & 0x7fffffff;
    return 'dev-${now.toRadixString(16)}-${rand.toRadixString(16)}';
  }

  Future<void> _initRoomCode() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString('room_code') ?? 'demo';
      _roomCode = saved;
      _roomController.text = saved;
      if (mounted) setState(() {});
    } catch (_) {
      _roomCode = 'demo';
      _roomController.text = 'demo';
    }
  }

  Future<void> _applyRoomCode() async {
    if (_nanStarting) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在启动中，请稍后再试')));
      return;
    }
    final raw = _roomController.text.trim();
    final valid = RegExp(r'^[A-Za-z0-9_-]{1,20}$');
    if (!valid.hasMatch(raw)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('房间码仅支持英文/数字/下划线/短横线，长度1-20')));
      return;
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('room_code', raw);
      setState(() => _roomCode = raw);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('房间码已设置为 $raw')));
      // 若已在运行，则重启使之生效
      if (_nanReady) {
        await _stopNan();
        await _startNan();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    }
  }

  Future<void> _stopNan() async {
    try {
      await _nan.invokeMethod('release');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _nanReady = false;
        _nanStatus = '已释放';
        _nanPeers = 0;
      });
    }
  }

  String _truncateUtf8(String s, int maxBytes) {
    final bytes = utf8.encode(s);
    if (bytes.length <= maxBytes) return s;
    int count = 0;
    final runes = s.runes.toList();
    final buf = StringBuffer();
    for (final r in runes) {
      final b = utf8.encode(String.fromCharCode(r));
      if (count + b.length > maxBytes) break;
      count += b.length;
      buf.writeCharCode(r);
    }
    return buf.toString() + '…';
  }

  String _wrapNanMessage({required String type, required String body}) {
    final id = _deviceId ?? 'unknown';
    _msgSeq++;
    final map = {
      'ver': 1,
      'type': type,
      'sender': id,
      'seq': _msgSeq,
      'ts': DateTime.now().toIso8601String(),
      'body': body,
    };
    return jsonEncode(map);
  }

  void _ensurePhotoOrNotify() {
    if (_photo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先拍照')),
      );
    }
  }

  Future<void> _analyzeWithOcr() async {
    if (_photo == null) {
      _ensurePhotoOrNotify();
      return;
    }
    if (_isAnalyzing) return;
    setState(() {
      _isAnalyzing = true;
      _resultText = null; // 清空上一条结果
    });
    // 模拟调用后端 OCR
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    setState(() {
      _isAnalyzing = false;
      _resultText = 'OCR 识别结果\n'
          '文本: "示例票据，金额￥128.00，日期2025-10-31"\n'
          '置信度: 0.98\n'
          '语言: zh-CN';
    });
  }

  Future<void> _analyzeWithVlm() async {
    if (_photo == null) {
      _ensurePhotoOrNotify();
      return;
    }
    if (_isAnalyzing) return;
    setState(() {
      _isAnalyzing = true;
      _resultText = null;
    });
    // 模拟调用后端 VLM（多模态理解）
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    setState(() {
      _isAnalyzing = false;
      _resultText = 'VLM 分析结果\n'
          '描述: "一张发票照片，抬头为示例公司，金额约128元，日期为2025年10月31日"\n'
          '关键信息: {vendor: "示例公司", amount: 128.00, date: "2025-10-31"}';
    });
  }

  // === NAN（附近直连）实验性调用 ===
  Future<void> _startNan() async {
    try {
      if (_nanStarting || _nanReady) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('附近直连已在运行')));
        return;
      }
      setState(() => _nanStarting = true);
      // 1) 申请必要权限（定位 + Android 13+ 附近 Wi‑Fi 设备）
      if (Platform.isAndroid) {
        final ok = await _ensureNanPermissions();
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('缺少必要权限，无法启动附近直连')));
          setState(() => _nanStarting = false);
          return;
        }
      }

      // 确保已有设备ID，用于 SSI 和消息信封
      if (_deviceId == null) {
        await _initDeviceId();
      }

      final bool available = await _nan.invokeMethod('isAvailable');
      if (!available) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('此设备/系统不支持 Wi‑Fi Aware')));
        setState(() => _nanStarting = false);
        return;
      }
      final bool locOn = await _nan.invokeMethod('isLocationEnabled');
      if (!locOn) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先开启定位服务')));
        // 继续 attach 也可能失败，这里仅提醒
      }
      await _nan.invokeMethod('attach');
      await _nan.invokeMethod('publish', {
        'serviceName': 'aiocr_room',
        'ssi': 'room=${_roomCode ?? 'demo'};dev=${_deviceId ?? 'unknown'}',
        'broadcast': true,
      });
      await _nan.invokeMethod('subscribe', {
        'serviceName': 'aiocr_room',
        'ssi': 'room=${_roomCode ?? 'demo'};dev=${_deviceId ?? 'unknown'}',
      });
      setState(() => _nanReady = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('附近直连已启动（发布+订阅）')));
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('NAN 启动失败: ${e.message}')));
    }
    finally {
      if (mounted) setState(() => _nanStarting = false);
    }
  }

  Future<void> _broadcastNan() async {
    try {
      final msg = _wrapNanMessage(type: 'text', body: 'hello from flutter');
      await _nan.invokeMethod('broadcast', {'text': msg});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已尝试广播 hello')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('广播失败: $e')));
    }
  }

  Future<void> _sendAnalysisOverNan() async {
    if (!_nanReady) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先启动附近直连')));
      return;
    }
    final text = _resultText;
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有可发送的分析结果')));
      return;
    }
    // 构造 envelope，整体限制 ~900 字节
    String payload = _truncateUtf8(text, 760); // 预留一些字节给 JSON 元数据
    final msg = _wrapNanMessage(type: 'analysis', body: payload);
    final msgTrimmed = _truncateUtf8(msg, 900);
    try {
      await _nan.invokeMethod('broadcast', {'text': msgTrimmed});
      _appendNanLog('broadcast analysis (${payload.length} chars)');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已通过 NAN 发送分析结果')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
      }
    }
  }

  Future<bool> _ensureNanPermissions() async {
    // 定位权限
    final loc = await Permission.locationWhenInUse.request();
    // Android 13+ 附近 Wi‑Fi 设备
    PermissionStatus nearbyStatus = PermissionStatus.granted;
    try {
      nearbyStatus = await Permission.nearbyWifiDevices.request();
    } catch (_) {
      // 在低版本上此权限不可用，忽略
    }
    final granted = (loc.isGranted || loc.isLimited) && (nearbyStatus.isGranted || nearbyStatus.isLimited || nearbyStatus.isDenied);
    // 注意：nearby 在低版本可能返回 denied，不影响旧系统
    if (!granted) {
      if (loc.isPermanentlyDenied || nearbyStatus.isPermanentlyDenied) {
        await openAppSettings();
      }
    }
    return granted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: SafeArea(
        bottom: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 房间码设置
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text('房间码', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(width: 8),
                          if (_roomCode != null)
                            Chip(label: Text(_roomCode!)),
                          const Spacer(),
                          TextButton(
                            onPressed: _nanReady || _nanStarting ? _stopNan : null,
                            child: const Text('停止附近直连'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _roomController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: '输入房间码（1-20位，英文/数字/_/-）',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _applyRoomCode,
                            child: const Text('应用房间码'),
                          )
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '预览区',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 260,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Card(
                    child: _photo == null
                        ? const Center(
                            child: Text(
                              '还没有照片，点击下方“拍照”开始',
                              style: TextStyle(color: Colors.black54),
                            ),
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(_photo!.path),
                              fit: BoxFit.cover,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  final result = await Navigator.of(context).push<XFile>(
                    MaterialPageRoute(
                      builder: (_) => const CameraCapturePage(),
                    ),
                  );
                  if (!mounted) return;
                  if (result != null) {
                    setState(() => _photo = result);
                  }
                },
                icon: const Icon(Icons.photo_camera),
                label: const Text('拍照'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isAnalyzing ? null : _analyzeWithOcr,
                      icon: const Icon(Icons.text_fields),
                      label: const Text('OCR 识别'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isAnalyzing ? null : _analyzeWithVlm,
                      icon: const Icon(Icons.psychology),
                      label: const Text('VLM 分析'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('附近直连（NAN 实验）', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text('状态: $_nanStatus')),
                  Chip(label: Text('Peers: $_nanPeers')),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _startNan,
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('启动发布+订阅'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _nanReady ? _broadcastNan : null,
                      icon: const Icon(Icons.volume_up),
                      label: const Text('广播 Hello'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: (_nanReady && _resultText != null && _resultText!.isNotEmpty) ? _sendAnalysisOverNan : null,
                  icon: const Icon(Icons.send),
                  label: const Text('通过 NAN 发送分析结果'),
                ),
              ),
              const SizedBox(height: 12),
              // 分析结果区域
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text('分析结果', style: Theme.of(context).textTheme.titleMedium),
                          const Spacer(),
                          TextButton(
                            onPressed: _resultText == null && !_isAnalyzing
                                ? null
                                : () => setState(() => _resultText = null),
                            child: const Text('清空'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 160,
                        child: _isAnalyzing
                            ? const Center(child: CircularProgressIndicator())
                            : (_resultText == null
                                ? const Center(child: Text('暂无分析结果'))
                                : SingleChildScrollView(
                                    child: Text(
                                      _resultText!,
                                      style: const TextStyle(height: 1.4),
                                    ),
                                  )),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // NAN 日志区域（固定高度，避免在可滚动页面中使用 Expanded）
              SizedBox(
                height: 240,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text('NAN 日志', style: Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            TextButton(
                              onPressed: _nanLogs.isEmpty ? null : () => setState(() => _nanLogs.clear()),
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _nanLogs.isEmpty
                              ? const Center(child: Text('暂无 NAN 日志'))
                              : ListView.builder(
                                  itemCount: _nanLogs.length,
                                  itemBuilder: (context, i) => Text(_nanLogs[i]),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
