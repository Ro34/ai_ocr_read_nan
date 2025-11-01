import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key});

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage> with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;
  XFile? _capturedFile;
  CameraDescription? _selectedCamera;
  Offset? _lastFocusIndicator; // 预览内的点击位置（像素坐标，仅用于显示对焦框）

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;

    // App state changed before we got the chance to initialize.
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      // Re-initialize the camera with same description
      _recreateController();
    }
  }

  Future<void> _initCamera() async {
    try {
      // Ensure plugin services are initialized
      WidgetsFlutterBinding.ensureInitialized();

      final List<CameraDescription> cameras = await availableCameras();
      CameraDescription? back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.isNotEmpty ? cameras.first : throw ('No camera available'),
      );
      _selectedCamera = back;
      await _createController(back);
    } catch (e) {
      if (!mounted) return;
      _showError('无法初始化相机: $e');
    }
  }

  Future<void> _createController(CameraDescription description) async {
    final controller = CameraController(
      description,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    setState(() {
      _controller = controller;
      _initializeControllerFuture = controller.initialize();
    });

    try {
      await _initializeControllerFuture;
      // 初始化后尝试设置为自动对焦模式
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      _showError('初始化相机失败: $e');
    }
  }

  Future<void> _recreateController() async {
    final cam = _selectedCamera;
    if (cam == null) return;
    await _createController(cam);
  }

  Future<void> _onCapture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || controller.value.isTakingPicture) return;
    try {
      await controller.setFlashMode(FlashMode.off);
      final XFile file = await controller.takePicture();
      if (!mounted) return;
      setState(() => _capturedFile = file);
    } catch (e) {
      _showError('拍照失败: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('拍照'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: _capturedFile == null ? _buildLivePreview() : _buildCapturedPreview(),
      ),
    );
  }

  Widget _buildLivePreview() {
    final future = _initializeControllerFuture;
    final ctrl = _controller;
    if (future == null || ctrl == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return FutureBuilder<void>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        final aspect = ctrl.value.aspectRatio;
        // 注意：camera 插件返回的 aspectRatio 以横屏为基准，
        // 竖屏时需取倒数，否则会显得“被压扁”。
        final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
        final previewAspect = isPortrait ? (1 / aspect) : aspect;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 使用相机原生宽高比，减少额外缩放带来的模糊
            Center(
              child: AspectRatio(
                aspectRatio: previewAspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(ctrl),
                    // 手势层：点击设置对焦/曝光点
                    _TapToFocusLayer(
                      onTapInPreview: (localPos, size) async {
                        final dx = (localPos.dx / size.width).clamp(0.0, 1.0);
                        final dy = (localPos.dy / size.height).clamp(0.0, 1.0);
                        try {
                          await ctrl.setFocusPoint(Offset(dx, dy));
                        } catch (_) {}
                        try {
                          await ctrl.setExposurePoint(Offset(dx, dy));
                        } catch (_) {}
                        if (!mounted) return;
                        setState(() => _lastFocusIndicator = localPos);
                        // 一段时间后隐藏对焦框
                        Future.delayed(const Duration(seconds: 1), () {
                          if (mounted) setState(() => _lastFocusIndicator = null);
                        });
                      },
                      focusIndicator: _lastFocusIndicator,
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 64.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ShutterButton(onTap: _onCapture),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCapturedPreview() {
    final XFile file = _capturedFile!;
    final Widget imageWidget = kIsWeb
        ? Image.network(file.path, fit: BoxFit.contain)
        : Image.file(File(file.path), fit: BoxFit.contain);

    return Column(
      children: [
        Expanded(
          child: Container(color: Colors.black, child: Center(child: imageWidget)),
        ),
        Container(
          color: Colors.black,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70)),
                  onPressed: () {
                    setState(() => _capturedFile = null);
                  },
                  child: const Text('重拍'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.greenAccent[700]),
                  onPressed: () {
                    Navigator.of(context).pop(file);
                  },
                  child: const Text('确认'),
                ),
              ),
            ],
          ),
        )
      ],
    );
  }
}

class _TapToFocusLayer extends StatelessWidget {
  final void Function(Offset localPosition, Size size) onTapInPreview;
  final Offset? focusIndicator;
  const _TapToFocusLayer({required this.onTapInPreview, required this.focusIndicator});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onTapInPreview(d.localPosition, size),
          child: Stack(
            children: [
              if (focusIndicator != null)
                Positioned(
                  left: focusIndicator!.dx - 30,
                  top: focusIndicator!.dy - 30,
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ShutterButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Center(
          child: Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
