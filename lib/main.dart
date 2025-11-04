import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'camera_capture_page.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class _BuiltMsg {
  final String message;
  final bool truncated;
  const _BuiltMsg(this.message, this.truncated);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF10B981);
    final baseLight = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light);
    final lightScheme = baseLight.copyWith(
      secondary: const Color(0xFF06B6D4),
      tertiary: const Color(0xFF84CC16),
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
  String? _roomCode;
  final TextEditingController _roomController = TextEditingController();
  int? _nanMaxMsgLen;
  String? _backendBaseUrl;
  final TextEditingController _backendController = TextEditingController();
  final List<String> _debugLogs = [];

  @override
  void initState() {
    super.initState();
    _initDeviceId();
    _initRoomCode();
    _initBackendBaseUrl();
    _nanSub = _nanEvents.receiveBroadcastStream().listen((event) {
      if (!mounted) return;
      try {
        final map = Map<String, dynamic>.from(event as Map);
        final type = map['type'] as String?;
        switch (type) {
          case 'maxMessageLen':
            final max = map['max'];
            _appendNanLog('maxMessageLen=$max');
            debugPrint('NAN maxMessageLen=$max');
            break;
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
      } catch (_) {}
    });
  }

  void _appendNanLog(String line) {
    setState(() {
      _nanLogs.add(line);
      if (_nanLogs.length > 100) _nanLogs.removeAt(0);
    });
    // 同时打印到控制台，便于在 `flutter run` 的输出中查看
    debugPrint('[NAN] $line');
  }

  void _appendDebug(String line) {
    setState(() {
      final ts = DateTime.now().toIso8601String();
      _debugLogs.add('[$ts] $line');
      if (_debugLogs.length > 200) _debugLogs.removeAt(0);
    });
    // 也打印到控制台，确保在运行 `flutter run` 时能看到
    debugPrint('[DEBUG] $line');
  }

  Future<void> _copyDebugToClipboard() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_debugLogs.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可复制的调试信息')));
      return;
    }
    final text = _debugLogs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('调试信息已复制到剪贴板')));
  }

  Future<void> _copyNanLogsToClipboard() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_nanLogs.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可复制的 NAN 日志')));
      return;
    }
    final text = _nanLogs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('NAN 日志已复制到剪贴板')));
  }

  @override
  void dispose() {
    _nanSub?.cancel();
    _roomController.dispose();
    _backendController.dispose();
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
    final messenger = ScaffoldMessenger.of(context);
    if (_nanStarting) {
      messenger.showSnackBar(const SnackBar(content: Text('正在启动中，请稍后再试')));
      return;
    }
    final raw = _roomController.text.trim();
    final valid = RegExp(r'^[A-Za-z0-9_-]{1,20}$');
    if (!valid.hasMatch(raw)) {
      messenger.showSnackBar(const SnackBar(content: Text('房间码仅支持英文/数字/下划线/短横线，长度1-20')));
      return;
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('room_code', raw);
      if (!mounted) return;
      setState(() => _roomCode = raw);
      messenger.showSnackBar(SnackBar(content: Text('房间码已设置为 $raw')));
      if (_nanReady) {
        await _stopNan();
        await _startNan();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败: $e')));
    }
  }

  Future<void> _initBackendBaseUrl() async {
    try {
      final sp = await SharedPreferences.getInstance();
      var saved = sp.getString('backend_base_url');
      if (saved == null || saved.isEmpty) {
        saved = 'http://192.168.0.90:8000';
      }
      _backendBaseUrl = saved;
      _backendController.text = saved;
      if (mounted) setState(() {});
    } catch (_) {
      _backendBaseUrl = 'http://192.168.0.90:8000';
      _backendController.text = _backendBaseUrl!;
    }
  }

  Future<void> _applyBackendUrl() async {
    final messenger = ScaffoldMessenger.of(context);
    final raw = _backendController.text.trim();
    final ok = Uri.tryParse(raw);
    if (ok == null || !(ok.isScheme('http') || ok.isScheme('https'))) {
      messenger.showSnackBar(const SnackBar(content: Text('请输入合法的 http(s) 地址')));
      _appendDebug('后端地址非法：$raw');
      return;
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('backend_base_url', raw);
      if (!mounted) return;
      setState(() => _backendBaseUrl = raw);
      messenger.showSnackBar(SnackBar(content: Text('后端地址已设置为 $raw')));
      _appendDebug('后端地址已设置为 $raw');
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败: $e')));
      _appendDebug('保存后端地址失败: $e');
    }
  }

  Future<void> _testBackendHealth() async {
    try {
      final base = _backendBaseUrl ?? _backendController.text.trim();
      if (base.isEmpty) throw Exception('后端地址未设置');
      final uri = Uri.parse('$base/health');
      final started = DateTime.now();
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (resp.statusCode == 200) {
        _appendDebug('后端健康检查 OK ($ms ms)');
      } else {
        _appendDebug('后端返回 ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      _appendDebug('健康检查失败: $e');
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
    return '$buf…';
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
      _resultText = null;
    });
    try {
      final base = _backendBaseUrl;
      if (base == null || base.isEmpty) throw Exception('后端地址未设置');
      final uri = Uri.parse('$base/ocr');
      final req = http.MultipartRequest('POST', uri)
        ..fields['languages'] = 'ch_sim,en'
        ..files.add(await http.MultipartFile.fromPath('file', _photo!.path));
      final resp = await http.Response.fromStream(await req.send());
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
      final data = jsonDecode(resp.body);
      final text = data['text']?.toString() ?? '';
      final avgConf = data['avg_confidence'];
      final langs = (data['languages'] as List?)?.join(',') ?? '';
      if (!mounted) return;
      setState(() {
        _isAnalyzing = false;
        _resultText = 'OCR 识别结果\n文本:\n$text\n\n平均置信度: ${avgConf ?? '-'}\n语言: $langs';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAnalyzing = false);
      _appendDebug('OCR 调用失败: $e');
    }
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
    try {
      final base = _backendBaseUrl;
      if (base == null || base.isEmpty) throw Exception('后端地址未设置');
      final uri = Uri.parse('$base/vlm');
      final req = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', _photo!.path));
      final resp = await http.Response.fromStream(await req.send());
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
      final data = jsonDecode(resp.body);
      final desc = data['description']?.toString() ?? '';
      if (!mounted) return;
      setState(() {
        _isAnalyzing = false;
        _resultText = 'VLM 分析结果\n描述: $desc';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAnalyzing = false);
      _appendDebug('VLM 调用失败: $e');
    }
  }

  Future<void> _startNan() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_nanStarting || _nanReady) {
        messenger.showSnackBar(const SnackBar(content: Text('附近直连已在运行')));
        return;
      }
      setState(() => _nanStarting = true);
      if (Platform.isAndroid) {
        final ok = await _ensureNanPermissions();
        if (!ok) {
          messenger.showSnackBar(const SnackBar(content: Text('缺少必要权限，无法启动附近直连')));
          setState(() => _nanStarting = false);
          return;
        }
      }
      if (_deviceId == null) {
        await _initDeviceId();
      }
      final bool available = await _nan.invokeMethod('isAvailable');
      if (!available) {
        messenger.showSnackBar(const SnackBar(content: Text('此设备/系统不支持 Wi‑Fi Aware')));
        setState(() => _nanStarting = false);
        return;
      }
      final bool locOn = await _nan.invokeMethod('isLocationEnabled');
      if (!locOn) {
        messenger.showSnackBar(const SnackBar(content: Text('请先开启定位服务')));
      }
      await _nan.invokeMethod('attach');
      if (Platform.isAndroid) {
        try {
          final int maxLen = await _nan.invokeMethod('getMaxMessageLength');
          if (mounted) setState(() => _nanMaxMsgLen = maxLen > 0 ? maxLen : 1800);
          _appendNanLog('maxMessageLen=$maxLen');
        } catch (_) {
          if (mounted) setState(() => _nanMaxMsgLen = 1800);
        }
      }
      await _nan.invokeMethod('publish', {
        'serviceName': 'aiocr_room',
        'ssi': 'room=${_roomCode ?? 'demo'};dev=${_deviceId ?? 'unknown'}',
        'broadcast': true,
      });
      await _nan.invokeMethod('subscribe', {
        'serviceName': 'aiocr_room',
        'ssi': 'room=${_roomCode ?? 'demo'};dev=${_deviceId ?? 'unknown'}',
      });
      if (!mounted) return;
      setState(() => _nanReady = true);
      messenger.showSnackBar(const SnackBar(content: Text('附近直连已启动（发布+订阅）')));
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('NAN 启动失败: ${e.message}')));
    } finally {
      if (mounted) setState(() => _nanStarting = false);
    }
  }

  Future<void> _broadcastNan() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final built = await _buildNanMessageRespectingLimit(type: 'text', body: 'hello from flutter');
      await _nan.invokeMethod('broadcast', {'text': built.message});
      if (built.truncated) _appendNanLog('消息已按上限截断后发送');
      messenger.showSnackBar(const SnackBar(content: Text('已尝试广播 hello')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('广播失败: $e')));
    }
  }

  Future<void> _sendAnalysisOverNan() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_nanReady) {
      messenger.showSnackBar(const SnackBar(content: Text('请先启动附近直连')));
      return;
    }
    final text = _resultText;
    if (text == null || text.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可发送的分析结果')));
      return;
    }
    try {
      final built = await _buildNanMessageRespectingLimit(type: 'analysis', body: text);
      await _nan.invokeMethod('broadcast', {'text': built.message});
      _appendNanLog('broadcast analysis (truncated=${built.truncated})');
      if (mounted) messenger.showSnackBar(const SnackBar(content: Text('已通过 NAN 发送分析结果')));
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('发送失败: $e')));
    }
  }

  Future<void> _rawBroadcastOversized() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_nanReady) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(behavior: SnackBarBehavior.fixed, content: Text('请先启动附近直连')));
      return;
    }
    final body = 'A' * 2500;
    final msg = _wrapNanMessage(type: 'text', body: body);
    try {
      await _nan.invokeMethod('broadcast', {'text': msg});
      _appendNanLog('raw broadcast 2500B -> sent (may fail)');
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(behavior: SnackBarBehavior.fixed, content: Text('已发送原始超长消息（观察结果）')));
    } catch (e) {
      _appendNanLog('raw broadcast error: $e');
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.fixed, content: Text('发送失败: $e')));
    }
  }

  Future<void> _safeBroadcastOversized() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_nanReady) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(behavior: SnackBarBehavior.fixed, content: Text('请先启动附近直连')));
      return;
    }
    final body = 'A' * 2500;
    final built = await _buildNanMessageRespectingLimit(type: 'text', body: body);
    try {
      await _nan.invokeMethod('broadcast', {'text': built.message});
      _appendNanLog('safe broadcast 2500B -> truncated=${built.truncated}');
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(behavior: SnackBarBehavior.fixed, content: Text('已通过安全构建发送（可能已截断）')));
    } catch (e) {
      _appendNanLog('safe broadcast error: $e');
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.fixed, content: Text('发送失败: $e')));
    }
  }

  Future<int> _ensureNanMaxMessageLen() async {
    if (_nanMaxMsgLen != null) return _nanMaxMsgLen!;
    if (!Platform.isAndroid) return 900;
    try {
      final int v = await _nan.invokeMethod('getMaxMessageLength');
      _nanMaxMsgLen = v > 0 ? v : 1800;
      return _nanMaxMsgLen!;
    } catch (_) {
      _nanMaxMsgLen = 1800;
      return _nanMaxMsgLen!;
    }
  }

  Future<_BuiltMsg> _buildNanMessageRespectingLimit({required String type, required String body}) async {
    final maxLen = await _ensureNanMaxMessageLen();
    String candidate = _wrapNanMessage(type: type, body: body);
    List<int> bytes = utf8.encode(candidate);
    if (bytes.length <= maxLen) return _BuiltMsg(candidate, false);
    int low = 0;
    int high = utf8.encode(body).length;
    String best = candidate;
    bool truncated = false;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final testBody = _truncateUtf8(body, mid);
      final testMsg = _wrapNanMessage(type: type, body: testBody);
      final len = utf8.encode(testMsg).length;
      if (len <= maxLen) {
        truncated = mid < utf8.encode(body).length;
        best = testMsg;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return _BuiltMsg(best, truncated);
  }

  Future<bool> _ensureNanPermissions() async {
    final loc = await Permission.locationWhenInUse.request();
    PermissionStatus nearbyStatus = PermissionStatus.granted;
    try {
      nearbyStatus = await Permission.nearbyWifiDevices.request();
    } catch (_) {}
    final granted = (loc.isGranted || loc.isLimited) && (nearbyStatus.isGranted || nearbyStatus.isLimited || nearbyStatus.isDenied);
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
                          if (_roomCode != null) Chip(label: Text(_roomCode!)),
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
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text('后端地址', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(width: 8),
                          if (_backendBaseUrl != null) Chip(label: Text(_backendBaseUrl!, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _backendController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: '如 http://192.168.0.90:8000（真机访问局域网）',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(onPressed: _applyBackendUrl, child: const Text('应用地址')),
                          const SizedBox(width: 8),
                          OutlinedButton(onPressed: _testBackendHealth, child: const Text('测试连接')),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('预览区', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SizedBox(
                height: 260,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Card(
                    child: _photo == null
                        ? const Center(child: Text('还没有照片，点击下方“拍照”开始', style: TextStyle(color: Colors.black54)))
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(File(_photo!.path), fit: BoxFit.cover),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  final result = await Navigator.of(context).push<XFile>(
                    MaterialPageRoute(builder: (_) => const CameraCapturePage()),
                  );
                  if (!mounted) return;
                  if (result != null) setState(() => _photo = result);
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(onPressed: _nanReady ? _rawBroadcastOversized : null, child: const Text('测试：直接发送 2500B（绕过截断）')),
                  OutlinedButton(onPressed: _nanReady ? _safeBroadcastOversized : null, child: const Text('测试：通过安全构建发送 2500B（会截断）')),
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
                            onPressed: _resultText == null && !_isAnalyzing ? null : () => setState(() => _resultText = null),
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
                                : SingleChildScrollView(child: Text(_resultText!, style: const TextStyle(height: 1.4)))),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 200,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text('错误/调试信息', style: Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(onPressed: _debugLogs.isEmpty ? null : () => setState(() => _debugLogs.clear()), child: const Text('清空')),
                                const SizedBox(width: 8),
                                TextButton(onPressed: _debugLogs.isEmpty ? null : _copyDebugToClipboard, child: const Text('复制')),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _debugLogs.isEmpty
                              ? const Center(child: Text('暂无错误/调试信息'))
                              : ListView.builder(itemCount: _debugLogs.length, itemBuilder: (context, i) => Text(_debugLogs[i])),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
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
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton(onPressed: _nanLogs.isEmpty ? null : () => setState(() => _nanLogs.clear()), child: const Text('清空')),
                                const SizedBox(width: 8),
                                TextButton(onPressed: _nanLogs.isEmpty ? null : _copyNanLogsToClipboard, child: const Text('复制')),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _nanLogs.isEmpty
                              ? const Center(child: Text('暂无 NAN 日志'))
                              : ListView.builder(itemCount: _nanLogs.length, itemBuilder: (context, i) => Text(_nanLogs[i])),
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
 
