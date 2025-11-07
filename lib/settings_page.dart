import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _backendController = TextEditingController();
  bool _isTesting = false;
  String? _testResult;
  bool? _testSuccess;
  List<String> _recentUrls = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _backendController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final url = sp.getString('backend_base_url') ?? 'http://192.168.0.90:8000';
      final recent = sp.getStringList('recent_backend_urls') ?? [];
      
      setState(() {
        _backendController.text = url;
        _recentUrls = recent;
      });
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    final raw = _backendController.text.trim();

    if (raw.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请输入后端地址')),
      );
      return;
    }

    final ok = Uri.tryParse(raw);
    if (ok == null || !(ok.isScheme('http') || ok.isScheme('https'))) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请输入合法的 http:// 或 https:// 地址')),
      );
      return;
    }

    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('backend_base_url', raw);
      
      // 保存到历史记录
      final recent = sp.getStringList('recent_backend_urls') ?? [];
      if (!recent.contains(raw)) {
        recent.insert(0, raw);
        if (recent.length > 5) recent.removeLast();
        await sp.setStringList('recent_backend_urls', recent);
        setState(() => _recentUrls = recent);
      }

      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: const Text('保存成功!'),
          backgroundColor: Colors.green,
          action: SnackBarAction(
            label: '测试',
            textColor: Colors.white,
            onPressed: _testConnection,
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testResult = null;
      _testSuccess = null;
    });

    try {
      final base = _backendController.text.trim();
      if (base.isEmpty) throw Exception('请先输入后端地址');

      final uri = Uri.parse('$base/health');
      final started = DateTime.now();
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      final ms = DateTime.now().difference(started).inMilliseconds;

      if (!mounted) return;

      if (resp.statusCode == 200) {
        setState(() {
          _isTesting = false;
          _testSuccess = true;
          _testResult = '✅ 连接成功!\n响应时间: $ms ms\n状态: ${resp.body}';
        });
      } else {
        setState(() {
          _isTesting = false;
          _testSuccess = false;
          _testResult = '❌ 连接失败\nHTTP ${resp.statusCode}\n${resp.body}';
        });
      }
    } catch (e) {
      if (!mounted) return;

      String errorMsg = '❌ 连接失败\n';
      if (e.toString().contains('Failed host lookup') ||
          e.toString().contains('SocketException')) {
        errorMsg += '原因: 无法解析域名或连接服务器\n建议: 检查地址和网络连接';
      } else if (e.toString().contains('TimeoutException')) {
        errorMsg += '原因: 连接超时\n建议: 检查服务器是否运行';
      } else {
        errorMsg += '错误: $e';
      }

      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testResult = errorMsg;
      });
    }
  }

  void _usePresetUrl(String url) {
    setState(() {
      _backendController.text = url;
      _testResult = null;
      _testSuccess = null;
    });
  }

  Widget _buildPresetButtons() {
    final presets = [
      {'label': '本机 (模拟器)', 'url': 'http://localhost:8000', 'icon': Icons.computer},
      {'label': '本机 (Android)', 'url': 'http://10.0.2.2:8000', 'icon': Icons.android},
      {'label': '局域网示例', 'url': 'http://192.168.0.90:8000', 'icon': Icons.router},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '常用配置',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: presets.map((preset) {
            return ActionChip(
              avatar: Icon(preset['icon'] as IconData, size: 18),
              label: Text(preset['label'] as String),
              onPressed: () => _usePresetUrl(preset['url'] as String),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildRecentUrls() {
    if (_recentUrls.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          '最近使用',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        ...(_recentUrls.map((url) {
          return Card(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.history),
              title: Text(url, style: const TextStyle(fontSize: 13)),
              trailing: IconButton(
                icon: const Icon(Icons.arrow_forward, size: 18),
                onPressed: () => _usePresetUrl(url),
              ),
            ),
          );
        }).toList()),
      ],
    );
  }

  Widget _buildTestResult() {
    if (_testResult == null && !_isTesting) return const SizedBox.shrink();

    return Card(
      color: _testSuccess == true
          ? Colors.green.shade50
          : _testSuccess == false
              ? Colors.red.shade50
              : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _isTesting
            ? const Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('正在测试连接...'),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _testSuccess == true ? Icons.check_circle : Icons.error,
                        color: _testSuccess == true ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '测试结果',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _testResult!,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('后端 API 设置'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '配置说明',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '• 真机测试时,需要电脑和手机在同一局域网\n'
                      '• 使用电脑的局域网 IP 地址,如 192.168.0.90\n'
                      '• 确保后端服务已启动 (默认端口 8000)\n'
                      '• Android 模拟器使用 10.0.2.2 访问电脑 localhost',
                      style: TextStyle(fontSize: 13, height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '后端地址',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _backendController,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: '后端 URL',
                        hintText: 'http://192.168.0.90:8000',
                        prefixIcon: const Icon(Icons.link),
                        suffixIcon: _backendController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () => setState(() {
                                  _backendController.clear();
                                  _testResult = null;
                                  _testSuccess = null;
                                }),
                              )
                            : null,
                      ),
                      keyboardType: TextInputType.url,
                      onChanged: (_) => setState(() {
                        _testResult = null;
                        _testSuccess = null;
                      }),
                    ),
                    const SizedBox(height: 16),
                    _buildPresetButtons(),
                    _buildRecentUrls(),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _saveSettings,
                            icon: const Icon(Icons.save),
                            label: const Text('保存设置'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isTesting ? null : _testConnection,
                            icon: const Icon(Icons.wifi_protected_setup),
                            label: const Text('测试连接'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildTestResult(),
          ],
        ),
      ),
    );
  }
}
