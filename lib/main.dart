import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'storage_saver.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(CameraToolsApp(cameras: cameras));
}

class CameraToolsApp extends StatelessWidget {
  const CameraToolsApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NightPlus Camera Tools',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.black),
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: CameraHome(cameras: cameras),
    );
  }
}

class CameraHome extends StatefulWidget {
  const CameraHome({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<CameraHome> createState() => _CameraHomeState();
}

enum CaptureFormat { jpeg, raw }

class _CameraHomeState extends State<CameraHome> {
  CameraController? _controller;
  CameraDescription? _activeCamera;
  bool _isStacking = false;
  double _progress = 0;
  String? _status;
  String? _lastSavedPath;

  int _framesToStack = 8;
  double _minExposureOffset = -2;
  double _maxExposureOffset = 2;
  double _exposureOffset = 0;
  double _focusDepth = 0.5;
  bool _focusSupported = false;
  bool _rawSupported = false;
  CaptureFormat _captureFormat = CaptureFormat.jpeg;

  Timer? _focusDebounce;
  Timer? _exposureDebounce;

  @override
  void initState() {
    super.initState();
    if (widget.cameras.isEmpty) {
      setState(() {
        _status = 'No cameras were detected on this device.';
      });
    } else {
      _initializeCamera(widget.cameras.first);
    }
  }

  @override
  void dispose() {
    _focusDebounce?.cancel();
    _exposureDebounce?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera(CameraDescription description) async {
    setState(() {
      _status = 'Preparing camera...';
    });

    final previous = _controller;
    _controller = null;
    await previous?.dispose();

    final controller = CameraController(
      description,
      ResolutionPreset.max,
      enableAudio: false,
    );

    try {
      await controller.initialize();

      double minExposure = -2;
      double maxExposure = 2;
      double exposure = 0;
      try {
        minExposure = await controller.getMinExposureOffset();
        maxExposure = await controller.getMaxExposureOffset();
        exposure = await controller.setExposureOffset(0);
      } on CameraException {
        minExposure = 0;
        maxExposure = 0;
        exposure = 0;
      }

      final bool focusSupported = controller.value.focusPointSupported && !kIsWeb;
      const bool rawSupported = false;

      if (focusSupported) {
        try {
          await controller.setFocusMode(FocusMode.locked);
          await controller.setFocusPoint(const Offset(0.5, 0.5));
        } on CameraException {
          // Ignore focus setup failures; controls will be disabled.
        }
      }

      setState(() {
        _controller = controller;
        _activeCamera = description;
        _status = null;
        _minExposureOffset = minExposure;
        _maxExposureOffset = maxExposure;
        _exposureOffset = exposure;
        _focusSupported = focusSupported;
        _rawSupported = rawSupported;
        if (!_rawSupported) {
          _captureFormat = CaptureFormat.jpeg;
        }
      });
    } on CameraException catch (error) {
      await controller.dispose();
      setState(() {
        _status = 'Camera error: ${error.description ?? error.code}';
      });
    } catch (error) {
      await controller.dispose();
      setState(() {
        _status = 'Failed to initialize camera: $error';
      });
    }
  }

  Future<void> _captureStackedImage() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isStacking) {
      return;
    }

    setState(() {
      _isStacking = true;
      _progress = 0;
      _status = 'Capturing $_framesToStack frames...';
    });

    final List<Uint8List> frameBytes = [];

    try {
      for (int i = 0; i < _framesToStack; i++) {
        final capture = await controller.takePicture();
        final bytes = await capture.readAsBytes();
        frameBytes.add(bytes);
        setState(() {
          _progress = (i + 1) / _framesToStack;
          _status = 'Captured ${i + 1} / $_framesToStack';
        });
      }

      final result = await compute(
        stackFrames,
        StackRequest(
          frames: frameBytes,
          outputRaw: _captureFormat == CaptureFormat.raw && _rawSupported,
        ),
      );

      final savedLocation = await saveStackResultBytes(
        result.bytes,
        result.extension,
      );

      setState(() {
        _lastSavedPath = savedLocation;
        _status = 'Saved to $savedLocation';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved $savedLocation')),
        );
      }
    } catch (error) {
      setState(() {
        _status = 'Capture failed: $error';
      });
    } finally {
      setState(() {
        _isStacking = false;
        _progress = 0;
      });
    }
  }

  void _changeExposure(double value) {
    _exposureDebounce?.cancel();
    setState(() {
      _exposureOffset = value;
    });
    _exposureDebounce = Timer(const Duration(milliseconds: 180), () async {
      final controller = _controller;
      if (controller == null) {
        return;
      }
      try {
        final applied = await controller.setExposureOffset(value);
        if (mounted) {
          setState(() {
            _exposureOffset = applied;
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _status = 'Exposure update failed: $error';
          });
        }
      }
    });
  }

  void _changeFocus(double value) {
    if (!_focusSupported || kIsWeb) {
      return;
    }
    _focusDebounce?.cancel();
    setState(() {
      _focusDepth = value;
    });
    _focusDebounce = Timer(const Duration(milliseconds: 120), () async {
      final controller = _controller;
      if (controller == null) {
        return;
      }
      try {
        await controller.setFocusMode(FocusMode.locked);
        await controller.setFocusPoint(Offset(0.5, 1 - value));
      } catch (error) {
        if (mounted) {
          setState(() {
            _status = 'Focus update failed: $error';
          });
        }
      }
    });
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2) {
      return;
    }
    final current = _activeCamera;
    if (current == null) {
      await _initializeCamera(widget.cameras.first);
      return;
    }
    final index = widget.cameras.indexOf(current);
    final next = widget.cameras[(index + 1) % widget.cameras.length];
    await _initializeCamera(next);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final hasPreview = controller != null && controller.value.isInitialized;
    final Size screenSize = MediaQuery.of(context).size;
    final double previewAspectRatio = () {
      final previewSize = controller?.value.previewSize;
      if (previewSize != null && previewSize.height != 0) {
        return previewSize.width / previewSize.height;
      }
      return screenSize.width / screenSize.height;
    }();

    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasPreview)
              Center(
                child: AspectRatio(
                  aspectRatio: previewAspectRatio,
                  child: CameraPreview(controller),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(),
              ),
            _buildOverlay(context),
            if (_isStacking) _buildProgressOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildTopBar(),
        _buildBottomPanel(context),
      ],
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              _status ?? 'Ready',
              style: const TextStyle(color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.cameras.length > 1)
            IconButton(
              color: Colors.white,
              onPressed: _isStacking ? null : _switchCamera,
              icon: const Icon(Icons.cameraswitch),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_lastSavedPath != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Last saved: $_lastSavedPath',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _buildFramesSlider(),
          const SizedBox(height: 12),
          _buildExposureSlider(),
          if (_focusSupported) ...[
            const SizedBox(height: 12),
            _buildFocusSlider(),
          ],
          const SizedBox(height: 16),
          _buildFormatToggle(),
          const SizedBox(height: 20),
          _buildCaptureButton(context),
        ],
      ),
    );
  }

  Widget _buildFramesSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Exposure length (frames)', style: TextStyle(color: Colors.white)),
            Text('${_framesToStack}x', style: const TextStyle(color: Colors.white70)),
          ],
        ),
        Slider(
          value: _framesToStack.toDouble(),
          min: 1,
          max: 30,
          divisions: 29,
          label: '$_framesToStack',
          onChanged: _isStacking
              ? null
              : (value) => setState(() => _framesToStack = value.round().clamp(1, 120)),
        ),
      ],
    );
  }

  Widget _buildExposureSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Exposure offset', style: TextStyle(color: Colors.white)),
            Text(_exposureOffset.toStringAsFixed(2), style: const TextStyle(color: Colors.white70)),
          ],
        ),
        Slider(
          value: _exposureOffset.clamp(_minExposureOffset, _maxExposureOffset),
          min: _minExposureOffset,
          max: _maxExposureOffset,
          onChanged: _isStacking ? null : _changeExposure,
        ),
      ],
    );
  }

  Widget _buildFocusSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [
            Text('Focus depth', style: TextStyle(color: Colors.white)),
            Text('Near                Far', style: TextStyle(color: Colors.white54)),
          ],
        ),
        Slider(
          value: _focusDepth,
          min: 0,
          max: 1,
          onChanged: _isStacking ? null : _changeFocus,
        ),
      ],
    );
  }

  Widget _buildFormatToggle() {
    final options = <CaptureFormat, String>{
      CaptureFormat.jpeg: 'JPEG',
      CaptureFormat.raw: 'RAW',
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Output format', style: TextStyle(color: Colors.white)),
        ToggleButtons(
          isSelected: options.keys.map((f) => f == _captureFormat).toList(),
          onPressed: (index) {
            final selected = options.keys.elementAt(index);
            if (selected == CaptureFormat.raw && !_rawSupported) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('RAW capture is not available for this camera.')),
                );
              }
              return;
            }
            setState(() {
              _captureFormat = selected;
            });
          },
          borderRadius: BorderRadius.circular(12),
          constraints: const BoxConstraints(minWidth: 72, minHeight: 36),
          children: options.values
              .map((label) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(label),
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _buildCaptureButton(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: _isStacking ? Colors.grey : Colors.white,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: const StadiumBorder(),
        ),
        onPressed: _isStacking ? null : _captureStackedImage,
        child: Text(_isStacking ? 'Capturing...' : 'Capture Stack'),
      ),
    );
  }

  Widget _buildProgressOverlay() {
    return Container(
      color: Colors.black38,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Stacking ${(100 * _progress).clamp(0, 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class StackRequest {
  const StackRequest({required this.frames, required this.outputRaw});

  final List<Uint8List> frames;
  final bool outputRaw;
}

class StackResult {
  const StackResult({required this.bytes, required this.extension});

  final Uint8List bytes;
  final String extension;
}

StackResult stackFrames(StackRequest request) {
  if (request.frames.isEmpty) {
    throw ArgumentError('No frames captured.');
  }

  final firstImage = img.decodeImage(request.frames.first);
  if (firstImage == null) {
    throw ArgumentError('Failed to decode the first frame.');
  }

  final width = firstImage.width;
  final height = firstImage.height;
  final pixelCount = width * height;
  final Float64List accumulator = Float64List(pixelCount * 3);
  int processedFrames = 0;

  void accumulate(Uint8List frame) {
    final decoded = img.decodeImage(frame);
    if (decoded == null) {
      return;
    }
    final image = (decoded.width == width && decoded.height == height)
        ? decoded
        : img.copyResize(decoded, width: width, height: height);
    final pixels = image.getBytes(order: img.ChannelOrder.rgb);
    for (var i = 0; i < pixels.length; i++) {
      accumulator[i] += pixels[i];
    }
    processedFrames++;
  }

  for (final frame in request.frames) {
    accumulate(frame);
  }

  if (processedFrames == 0) {
    throw ArgumentError('None of the frames could be decoded.');
  }

  final frameCount = processedFrames;

  if (request.outputRaw) {
    final Uint16List rawPixels = Uint16List(pixelCount * 3);
    for (var i = 0; i < rawPixels.length; i++) {
      final double normalized = accumulator[i] / frameCount / 255.0;
      rawPixels[i] = (normalized.clamp(0, 1) * 65535).round();
    }
    return StackResult(
      bytes: Uint8List.view(rawPixels.buffer),
      extension: 'raw',
    );
  }

  final Uint8List averagedPixels = Uint8List(pixelCount * 3);
  for (var i = 0; i < averagedPixels.length; i++) {
    averagedPixels[i] = (accumulator[i] / frameCount).clamp(0, 255).round();
  }

  final img.Image outputImage = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: averagedPixels.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );

  final Uint8List jpegBytes = Uint8List.fromList(
    img.encodeJpg(outputImage, quality: 95),
  );

  return StackResult(bytes: jpegBytes, extension: 'jpg');
}
