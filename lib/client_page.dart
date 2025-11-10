import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:async';

class ClientPage extends StatefulWidget {
  const ClientPage({super.key});

  @override
  State<ClientPage> createState() => _ClientPageState();
}

class _ClientPageState extends State<ClientPage> {
  bool _isSubscribed = false;
  bool _isReceiving = false;
  bool _hasReceivedContent = false;
  bool _isQuerying = false;
  bool _hasResult = false;
  String _receivedText = '';
  String _aiResponseText = '';
  String _processedAiResponse = '';
  final List<String> _mermaidDiagrams = [];
  final TextEditingController _questionController = TextEditingController();

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  // 简化数学公式显示，使其更易读
  String _simplifyMathInText(String text) {
    // 将 LaTeX 公式转换为更简单的文本格式
    return text
        // 常见的下标公式
        .replaceAll(r'$T_{RT}$', '`T_RT`')
        .replaceAll(r'$T_{delay}$', '`T_delay`')
        .replaceAll(r'$T_{roundA}$', '`T_roundA`')
        .replaceAll(r'$T_{replyA}$', '`T_replyA`')
        .replaceAll(r'$T_{roundB}$', '`T_roundB`')
        .replaceAll(r'$T_{replyB}$', '`T_replyB`')
        .replaceAll(r'$ToF$', '`ToF`')
        // 复杂公式
        .replaceAll(
          r'$Distance = (T_{RT} - T_{delay}) / 2$',
          '`Distance = (T_RT - T_delay) / 2`'
        )
        .replaceAll(
          r'$Distance = ToF \times speed\, of\, light$',
          '`Distance = ToF × speed of light`'
        )
        .replaceAll(
          r'$ToF = (T_{roundA} \times T_{roundB} - T_{replyA} \times T_{replyB}) / (T_{roundA} + T_{roundB} + T_{replyA} + T_{replyB})$',
          '`ToF = (T_roundA × T_roundB - T_replyA × T_replyB) / (T_roundA + T_roundB + T_replyA + T_replyB)`'
        )
        // 其他简单公式，直接用代码样式包裹
        .replaceAllMapped(
          RegExp(r'\$([^$]+)\$'),
          (match) => '`${match.group(1)}`'
        );
  }

  // 提取 Mermaid 代码块
  void _processMermaidDiagrams(String content) {
    _mermaidDiagrams.clear();
    final regex = RegExp(r'```mermaid\n([\s\S]*?)```', multiLine: true);
    final matches = regex.allMatches(content);
    
    for (final match in matches) {
      final diagram = match.group(1);
      if (diagram != null) {
        _mermaidDiagrams.add(diagram.trim());
      }
    }
    
    // 移除 Mermaid 代码块，替换为占位符
    _processedAiResponse = content.replaceAllMapped(
      regex,
      (match) => '\n**[流程图 ${_mermaidDiagrams.indexOf(match.group(1)!.trim()) + 1}]**\n',
    );
  }

  // 启动发布+订阅
  Future<void> _startSubscription() async {
    if (_isSubscribed || _isReceiving) return;

    setState(() {
      _isReceiving = true;
      _receivedText = '';
      _hasReceivedContent = false;
    });

    // 模拟连接延迟
    await Future.delayed(const Duration(milliseconds: 800));

    if (!mounted) return;

    setState(() {
      _isSubscribed = true;
      _isReceiving = false;
    });

    // 显示提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已启动发布+订阅'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 1),
        ),
      );
    }

    // 延时接收内容
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    // 加载 reply1.md 内容
    try {
      final content = await rootBundle.loadString('assets/reply1.md');
      // 简化表格中的数学公式
      final processedContent = _simplifyMathInText(content);
      setState(() {
        _receivedText = processedContent;
        _hasReceivedContent = true;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已接收到内容'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载内容失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _askAI() async {
    if (_isQuerying) return;

    final question = _questionController.text.trim();
    if (question.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请输入问题'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _isQuerying = true;
      _hasResult = false;
      _aiResponseText = '';
    });

    // 模拟网络请求延迟
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    // 加载 reply2.md 内容
    try {
      final content = await rootBundle.loadString('assets/reply2.md');
      final simplifiedContent = _simplifyMathInText(content);
      _processMermaidDiagrams(simplifiedContent);
      setState(() {
        _isQuerying = false;
        _hasResult = true;
        _aiResponseText = simplifiedContent;
      });

      // 显示完成提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AI 分析完成'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isQuerying = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('加载回答失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 启动发布+订阅按钮
              FilledButton.icon(
                onPressed: _isSubscribed || _isReceiving ? null : _startSubscription,
                icon: _isReceiving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Icon(_isSubscribed ? Icons.check_circle : Icons.cloud_sync),
                label: Text(
                  _isReceiving 
                      ? '正在连接...' 
                      : (_isSubscribed ? '已启动发布+订阅' : '启动发布+订阅')
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                  backgroundColor: _isSubscribed 
                      ? Colors.green 
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              
              const SizedBox(height: 20),
              
              // 接收内容区域
              Row(
                children: [
                  Text(
                    '接收内容',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  if (_isReceiving && !_hasReceivedContent) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Card(
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: 150,
                    maxHeight: 400,
                  ),
                  padding: const EdgeInsets.all(16),
                  child: _receivedText.isEmpty
                      ? Center(
                          child: Text(
                            '等待接收内容...',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          child: MarkdownBody(
                            data: _receivedText,
                            styleSheet: MarkdownStyleSheet(
                              p: Theme.of(context).textTheme.bodyMedium,
                              h1: Theme.of(context).textTheme.headlineSmall,
                              h2: Theme.of(context).textTheme.titleLarge,
                              h3: Theme.of(context).textTheme.titleMedium,
                              listBullet: Theme.of(context).textTheme.bodyMedium,
                              tableBody: Theme.of(context).textTheme.bodySmall,
                              code: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                    fontStyle: FontStyle.italic,
                                  ),
                            ),
                          ),
                        ),
                ),
              ),
              
              const SizedBox(height: 20),
              
              // 输入问题
              TextField(
                controller: _questionController,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: '输入您的问题',
                  hintText: '请输入想要询问 AI 的问题...',
                  prefixIcon: const Icon(Icons.question_answer),
                  suffixIcon: _questionController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() => _questionController.clear()),
                        )
                      : null,
                ),
                maxLines: 3,
                onChanged: (_) => setState(() {}),
              ),
              
              const SizedBox(height: 12),
              
              // 询问 AI 按钮
              FilledButton.icon(
                onPressed: _isQuerying ? null : _askAI,
                icon: _isQuerying
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(Icons.psychology),
                label: Text(_isQuerying ? '正在询问 AI...' : '询问 AI'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                ),
              ),
              
              const SizedBox(height: 20),
              
              // AI 回答内容区域
              if (_hasResult || _isQuerying) ...[
                Row(
                  children: [
                    Text(
                      'AI 回答',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(width: 8),
                    if (_isQuerying)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _isQuerying && _aiResponseText.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32.0),
                              child: Column(
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 16),
                                  Text('AI 正在思考中...'),
                                ],
                              ),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              MarkdownBody(
                                data: _processedAiResponse,
                                styleSheet: MarkdownStyleSheet(
                                  p: Theme.of(context).textTheme.bodyMedium,
                                  h1: Theme.of(context).textTheme.headlineSmall,
                                  h2: Theme.of(context).textTheme.titleLarge,
                                  h3: Theme.of(context).textTheme.titleMedium,
                                  code: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        fontFamily: 'monospace',
                                        backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                                      ),
                                  codeblockDecoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.surfaceVariant,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  listBullet: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              // 显示流程图图片
                              if (_mermaidDiagrams.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                const Divider(),
                                const SizedBox(height: 16),
                                Text(
                                  '流程图',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                const SizedBox(height: 12),
                                // 显示图片 1
                                if (_mermaidDiagrams.length > 0) ...[
                                  Card(
                                    clipBehavior: Clip.antiAlias,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.account_tree,
                                                size: 20,
                                                color: Theme.of(context).colorScheme.primary,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                '图 1: SS-TWR (单边双向测距)',
                                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Image.asset(
                                          'assets/1.png',
                                          fit: BoxFit.contain,
                                          errorBuilder: (context, error, stackTrace) {
                                            return Container(
                                              padding: const EdgeInsets.all(32),
                                              child: const Center(
                                                child: Text('无法加载图片'),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                // 显示图片 2
                                if (_mermaidDiagrams.length > 1) ...[
                                  Card(
                                    clipBehavior: Clip.antiAlias,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.account_tree,
                                                size: 20,
                                                color: Theme.of(context).colorScheme.primary,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                '图 2: DS-TWR (双边双向测距)',
                                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Image.asset(
                                          'assets/2.png',
                                          fit: BoxFit.contain,
                                          errorBuilder: (context, error, stackTrace) {
                                            return Container(
                                              padding: const EdgeInsets.all(32),
                                              child: const Center(
                                                child: Text('无法加载图片'),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ],
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
