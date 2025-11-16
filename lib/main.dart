import 'dart:async';
import 'dart:math' as math;

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

class _CameraHomeState extends State<CameraHome> {
  static const int _maxFrameCount = 180;
  static const double _fastShutterBias = -1.5;
  static const double _minDurationSeconds = 3;
  static const double _maxDurationSeconds = 20;
  static const double _minFramesPerSecond = 3;
  static const double _maxFramesPerSecond = 10;

  CameraController? _controller;
  CameraDescription? _activeCamera;
  bool _isCapturing = false;
  double _progress = 0;
  String? _status;
  String? _lastSavedPath;
  bool _controlsExpanded = false;

  double _captureDurationSeconds = 12;
  double _captureFramesPerSecond = 6;
  double _focusDepth = 0.5;
  bool _focusSupported = false;
  bool _autoFocusEnabled = true;
  bool _starEnhance = true;

  Timer? _focusDebounce;

  int get _plannedFrameCount =>
      math.max(1, (_captureDurationSeconds * _captureFramesPerSecond).round());

  int get _targetFrameCount => math.min(_plannedFrameCount, _maxFrameCount);

  bool get _isFrameCountClamped => _plannedFrameCount > _maxFrameCount;

  Future<void> _setAutoFocusEnabled(bool value) async {
    if (!_focusSupported) {
      return;
    }
    setState(() {
      _autoFocusEnabled = value;
    });

    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      if (value) {
        await controller.setFocusMode(FocusMode.auto);
      } else {
        await controller.setFocusMode(FocusMode.locked);
        await controller.setFocusPoint(Offset(0.5, 1 - _focusDepth));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _autoFocusEnabled = true;
        _status = 'Focus mode update failed: $error';
      });
    }
  }

  void _setStarEnhance(bool value) {
    setState(() {
      _starEnhance = value;
    });
  }

  Future<void> _openSettingsSheet() async {
    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 24,
            bottom: 16 + MediaQuery.of(sheetContext).padding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Night capture tips',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Use the sliders in the control panel to choose how long to shoot and how many frames to capture per second. NightPlus aligns each frame, blends noise away, and limits processing to $_maxFrameCount frames to keep things responsive.',
                style: const TextStyle(color: Colors.white70, height: 1.3),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tips',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '- Higher frame rates freeze motion but increase processing time.\n'
                '- Longer durations gather more light but rely on steadier hands or a tripod.\n'
                '- Keep an eye on the frame counter to balance quality and waiting time.',
                style: TextStyle(color: Colors.white54, height: 1.3),
              ),
            ],
          ),
        );
      },
    );
  }

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

      try {
        await controller.setExposureMode(ExposureMode.auto);
      } on CameraException {
        // If automatic exposure is unavailable, continue with defaults.
      }

      final bool focusSupported = controller.value.focusPointSupported && !kIsWeb;

      if (focusSupported) {
        try {
          await controller.setFocusMode(FocusMode.auto);
        } on CameraException {
          // Ignore focus setup failures; controls will be disabled.
        }
      }

      setState(() {
        _controller = controller;
        _activeCamera = description;
        _status = null;
        _focusSupported = focusSupported;
        _autoFocusEnabled = true;
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

  Future<void> _captureExposureSequence() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }

    final int plannedFrames = _plannedFrameCount;
    final int targetFrames = _targetFrameCount;
    if (targetFrames <= 0) {
      return;
    }

    final bool clamped = _isFrameCountClamped;
    final Duration frameInterval = Duration(
      microseconds: (1000000 / _captureFramesPerSecond).round(),
    );
    final Stopwatch frameStopwatch = Stopwatch();

    setState(() {
      _isCapturing = true;
      _progress = 0;
      _status = clamped
          ? 'Capturing $targetFrames / $plannedFrames frames…'
          : 'Capturing night stack ($targetFrames frames)…';
    });

    int capturedFrames = 0;
    final List<Uint8List> capturedBytes = <Uint8List>[];

    try {
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } on CameraException {
        // If automatic exposure is unavailable, continue.
      }

      try {
        await controller.setExposureOffset(_fastShutterBias);
      } on CameraException {
        // Some devices do not support biasing exposure toward faster shutters.
      }

      while (capturedFrames < targetFrames) {
        frameStopwatch
          ..reset()
          ..start();

        final XFile capture = await controller.takePicture();
        final Uint8List bytes = await capture.readAsBytes();
        capturedBytes.add(bytes);
        capturedFrames++;

        final Duration elapsed = frameStopwatch.elapsed;
        frameStopwatch
          ..stop()
          ..reset();

        if (elapsed < frameInterval) {
          await Future.delayed(frameInterval - elapsed);
        }

        if (!mounted) {
          return;
        }

        setState(() {
          _progress = capturedFrames / targetFrames;
          _status = clamped
              ? 'Captured $capturedFrames of $plannedFrames (limit $targetFrames)'
              : 'Captured $capturedFrames of $targetFrames frames';
        });
      }

      if (capturedBytes.isEmpty) {
        throw Exception('No usable frames captured');
      }

      if (mounted) {
        setState(() {
          _status = 'Processing frames (you can move now)…';
          _progress = 0.9;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Frames captured. You can move while we process.')),
        );
      }

      final _ProcessFramesResult processed = await compute(
        _processCapturedFrames,
        _ProcessFramesRequest(frames: capturedBytes, starEnhance: _starEnhance),
      );

      final savedLocation =
          await saveProcessedPhotoBytes(processed.jpegBytes, 'jpg');

      if (mounted) {
        setState(() {
          _lastSavedPath = savedLocation;
          _status = 'Saved night photo';
          _progress = 1;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              clamped
                  ? 'Saved ${processed.processedFrames} frames (requested $plannedFrames)'
                  : 'Night stack saved (${processed.processedFrames} frames)',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Capture failed: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
          _progress = 0;
        });
      }

      try {
        await controller.setExposureOffset(0);
      } catch (_) {
        // Ignore inability to restore exposure bias.
      }
    }
  }

  void _changeFocus(double value) {
    if (!_focusSupported || kIsWeb) {
      return;
    }
    if (_autoFocusEnabled) {
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
    final Size screenSize = MediaQuery.of(context).size;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null && controller.value.isInitialized)
              _buildCameraPreview(screenSize, controller),
            if (controller == null || !controller.value.isInitialized)
              const Center(
                child: CircularProgressIndicator(),
              ),
            _buildOverlay(context),
            if (_isCapturing) _buildProgressOverlay(),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.center,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withAlpha((0.35 * 255).round()),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  _status ?? 'READY',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _isCapturing ? null : _openSettingsSheet,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha((0.4 * 255).round()),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(8),
                child: const Icon(Icons.settings_outlined, color: Colors.white70),
              ),
            ),
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
          colors: [Colors.black, Colors.transparent],
        ),
      ),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 24 + MediaQuery.of(context).padding.bottom,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildControlHandle(),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_lastSavedPath != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Saved last to Photos',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  _buildCapturePlanner(),
                  if (_focusSupported) ...[
                    const SizedBox(height: 16),
                    _buildAutoFocusToggle(),
                    if (!_autoFocusEnabled) ...[
                      const SizedBox(height: 12),
                      _buildFocusSlider(),
                    ],
                  ],
                ],
              ),
            ),
            crossFadeState:
                _controlsExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 220),
          ),
          const SizedBox(height: 12),
          _buildCaptureBar(context),
        ],
      ),
    );
  }

  Widget _buildControlHandle() {
    return Center(
      child: GestureDetector(
        onTap: () => setState(() => _controlsExpanded = !_controlsExpanded),
        behavior: HitTestBehavior.translucent,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha((0.12 * 255).round()),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            _controlsExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureBar(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildPreviewButton(),
        _buildCaptureButton(context),
        _buildSwitcherButton(),
      ],
    );
  }

  Widget _buildPreviewButton() {
    return GestureDetector(
      onTap: () {
        if (_lastSavedPath != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Latest capture stored in Photos')),
          );
        }
      },
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24, width: 2),
          color: Colors.white10,
        ),
        child: const Icon(Icons.photo_library_outlined, color: Colors.white70),
      ),
    );
  }

  Widget _buildSwitcherButton() {
    return IconButton(
      iconSize: 32,
      color: Colors.white,
      onPressed: _isCapturing || widget.cameras.length < 2 ? null : _switchCamera,
      icon: const Icon(Icons.cameraswitch),
    );
  }

  Widget _buildCapturePlanner() {
    final int plannedFrames = _plannedFrameCount;
    final int targetFrames = _targetFrameCount;
    final bool clamped = _isFrameCountClamped;
    final double frameIntervalMs = 1000 / _captureFramesPerSecond;
    final double durationValue = _captureDurationSeconds
        .clamp(_minDurationSeconds, _maxDurationSeconds)
        .toDouble();
    final double fpsValue = _captureFramesPerSecond
        .clamp(_minFramesPerSecond, _maxFramesPerSecond)
        .toDouble();

    String framesLabel;
    if (clamped) {
      framesLabel = '$targetFrames frames (limited from $plannedFrames)';
    } else {
      framesLabel = '$plannedFrames frames planned';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Capture duration', style: TextStyle(color: Colors.white)),
            Text('${durationValue.toStringAsFixed(1)}s',
                style: const TextStyle(color: Colors.white70)),
          ],
        ),
        Slider(
          value: durationValue,
          min: _minDurationSeconds,
          max: _maxDurationSeconds,
          divisions: ((_maxDurationSeconds - _minDurationSeconds) * 2).round(),
          label: '${durationValue.toStringAsFixed(1)}s',
          onChanged: _isCapturing
              ? null
              : (value) {
                  setState(() {
                    _captureDurationSeconds = value;
                  });
                },
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Exposure rate', style: TextStyle(color: Colors.white)),
            Text('${fpsValue.toStringAsFixed(1)} fps',
                style: const TextStyle(color: Colors.white70)),
          ],
        ),
        Slider(
          value: fpsValue,
          min: _minFramesPerSecond,
          max: _maxFramesPerSecond,
          divisions: ((_maxFramesPerSecond - _minFramesPerSecond) * 2).round(),
          label: '${fpsValue.toStringAsFixed(1)} fps',
          onChanged: _isCapturing
              ? null
              : (value) {
                  setState(() {
                    _captureFramesPerSecond = value;
                  });
                },
        ),
        const SizedBox(height: 12),
        Text(
          framesLabel,
          style: const TextStyle(color: Colors.white70),
        ),
        Text(
          'Frame interval ≈ ${frameIntervalMs.toStringAsFixed(0)} ms',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        if (clamped)
          const Text(
            'Reduce duration or frame rate to stay within the processing limit.',
            style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Star highlight boost', style: TextStyle(color: Colors.white)),
            Switch.adaptive(
              value: _starEnhance,
              onChanged: _isCapturing ? null : _setStarEnhance,
            ),
          ],
        ),
        const Text(
          'Keeps bright pinpoints from the brightest frame and lifts deep shadows.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
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
            Text('Manual focus depth', style: TextStyle(color: Colors.white)),
            Text('Near                Far', style: TextStyle(color: Colors.white54)),
          ],
        ),
        Slider(
          value: _focusDepth,
          min: 0,
          max: 1,
          onChanged: _isCapturing ? null : _changeFocus,
        ),
      ],
    );
  }

  Widget _buildAutoFocusToggle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Auto focus', style: TextStyle(color: Colors.white)),
        Switch.adaptive(
          value: _autoFocusEnabled,
          activeTrackColor: Colors.white60,
          inactiveThumbColor: Colors.white70,
          inactiveTrackColor: Colors.white24,
          onChanged: _isCapturing ? null : _setAutoFocusEnabled,
        ),
      ],
    );
  }

  Widget _buildCaptureButton(BuildContext context) {
    return GestureDetector(
      onTap: _isCapturing ? null : _captureExposureSequence,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withAlpha((0.6 * 255).round()), width: 4),
          color: Colors.white.withAlpha(((_isCapturing ? 0.15 : 0.05) * 255).round()),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isCapturing ? Colors.white54 : Colors.white,
          ),
          child: _isCapturing
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildCameraPreview(Size screenSize, CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null || previewSize.height == 0) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      width: screenSize.width,
      height: screenSize.height,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.center,
        child: SizedBox(
          width: previewSize.width,
          height: previewSize.height,
          child: CameraPreview(controller),
        ),
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
              'Capturing ${(100 * _progress).clamp(0, 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessFramesRequest {
  const _ProcessFramesRequest({required this.frames, required this.starEnhance});

  final List<Uint8List> frames;
  final bool starEnhance;
}

class _ProcessFramesResult {
  const _ProcessFramesResult({required this.jpegBytes, required this.processedFrames});

  final Uint8List jpegBytes;
  final int processedFrames;
}

_ProcessFramesResult _processCapturedFrames(_ProcessFramesRequest request) {
  _DecodedFrame? referenceFrame;
  _FrameAccumulator? accumulator;
  int processedFrames = 0;

  for (final Uint8List bytes in request.frames) {
    final _DecodedFrame frame =
        _decodeFrame(_DecodeFrameRequest(bytes));
    if (!frame.isValid) {
      continue;
    }

    if (referenceFrame == null) {
      referenceFrame = frame;
      accumulator = _FrameAccumulator(frame.width, frame.height, frame.rgbBytes);
      accumulator.addFrame(frame.rgbBytes, dx: 0, dy: 0);
      processedFrames++;
      continue;
    }

    final _AlignmentResult alignment =
        _estimateAlignment(referenceFrame, frame);
    accumulator!.addFrame(frame.rgbBytes, dx: alignment.dx, dy: alignment.dy);
    processedFrames++;
  }

  if (accumulator == null || referenceFrame == null || processedFrames == 0) {
    throw ArgumentError('None of the frames could be processed.');
  }

  final _FinalizeNightImageRequest finalizeRequest = _FinalizeNightImageRequest(
    sums: accumulator.sums,
    sumSquares: accumulator.sumSquares,
    counts: accumulator.counts,
    reference: accumulator.reference,
    maxValues: accumulator.maxValues,
    width: accumulator.width,
    height: accumulator.height,
    starEnhance: request.starEnhance,
  );

  final Uint8List jpegBytes = _finalizeNightImage(finalizeRequest);
  return _ProcessFramesResult(
    jpegBytes: jpegBytes,
    processedFrames: processedFrames,
  );
}

class _DecodeFrameRequest {
  const _DecodeFrameRequest(this.bytes);

  final Uint8List bytes;
}

class _DecodedFrame {
  _DecodedFrame({
    required this.width,
    required this.height,
    required this.rgbBytes,
    required this.lowGray,
    required this.lowWidth,
    required this.lowHeight,
    required this.scaleX,
    required this.scaleY,
  });

  final int width;
  final int height;
  final Uint8List rgbBytes;
  final Uint8List lowGray;
  final int lowWidth;
  final int lowHeight;
  final double scaleX;
  final double scaleY;

  bool get isValid => rgbBytes.isNotEmpty;

  factory _DecodedFrame.empty() {
    return _DecodedFrame(
      width: 0,
      height: 0,
      rgbBytes: Uint8List(0),
      lowGray: Uint8List(0),
      lowWidth: 0,
      lowHeight: 0,
      scaleX: 1,
      scaleY: 1,
    );
  }
}

_DecodedFrame _decodeFrame(_DecodeFrameRequest request) {
  final img.Image? decoded = img.decodeImage(request.bytes);
  if (decoded == null) {
    return _DecodedFrame.empty();
  }

  final img.Image rgbImage = decoded.convert(numChannels: 3);
  final Uint8List rgbBytes = Uint8List.fromList(
    rgbImage.getBytes(order: img.ChannelOrder.rgb),
  );

  final int lowWidth = math.max(48, rgbImage.width ~/ 8);
  final int lowHeight = math.max(48, rgbImage.height ~/ 8);

  final img.Image lowRes = img.copyResize(
    rgbImage,
    width: lowWidth,
    height: lowHeight,
    interpolation: img.Interpolation.average,
  );

  final img.Image lowGrayImage = img.grayscale(lowRes);
  final Uint8List lowGray = Uint8List.fromList(lowGrayImage.getBytes());

  return _DecodedFrame(
    width: rgbImage.width,
    height: rgbImage.height,
    rgbBytes: rgbBytes,
    lowGray: lowGray,
    lowWidth: lowGrayImage.width,
    lowHeight: lowGrayImage.height,
    scaleX: rgbImage.width / lowGrayImage.width,
    scaleY: rgbImage.height / lowGrayImage.height,
  );
}

class _AlignmentResult {
  const _AlignmentResult({required this.dx, required this.dy});

  final int dx;
  final int dy;
}

_AlignmentResult _estimateAlignment(
  _DecodedFrame reference,
  _DecodedFrame frame,
) {
  final int width = math.min(reference.lowWidth, frame.lowWidth);
  final int height = math.min(reference.lowHeight, frame.lowHeight);
  const int searchRadius = 6;

  double bestScore = double.infinity;
  int bestDx = 0;
  int bestDy = 0;

  for (int dy = -searchRadius; dy <= searchRadius; dy++) {
    for (int dx = -searchRadius; dx <= searchRadius; dx++) {
      final int xStart = math.max(0, -dx);
      final int xEnd = math.min(width, width - dx);
      final int yStart = math.max(0, -dy);
      final int yEnd = math.min(height, height - dy);
      if (xStart >= xEnd || yStart >= yEnd) {
        continue;
      }

      double diff = 0;

      for (int y = yStart; y < yEnd; y++) {
        final int refRow = y * reference.lowWidth;
        final int frameRow = (y + dy) * frame.lowWidth;
        for (int x = xStart; x < xEnd; x++) {
          final int refIdx = refRow + x;
          final int frameIdx = frameRow + x + dx;
          final int delta = reference.lowGray[refIdx] - frame.lowGray[frameIdx];
          diff += delta * delta;
        }
      }

      final int count = (xEnd - xStart) * (yEnd - yStart);
      if (count == 0) {
        continue;
      }

      final double score = diff / count;
      if (score < bestScore) {
        bestScore = score;
        bestDx = dx;
        bestDy = dy;
      }
    }
  }

  final int highDx = (bestDx * reference.scaleX).round();
  final int highDy = (bestDy * reference.scaleY).round();
  return _AlignmentResult(dx: highDx, dy: highDy);
}

class _FrameAccumulator {
  _FrameAccumulator(this.width, this.height, Uint8List referenceBytes)
      : sums = Float64List(width * height * 3),
        sumSquares = Float64List(width * height * 3),
        counts = Int32List(width * height),
        reference = Uint8List.fromList(referenceBytes),
        maxValues = Uint8List.fromList(referenceBytes);

  final int width;
  final int height;
  final Float64List sums;
  final Float64List sumSquares;
  final Int32List counts;
  final Uint8List reference;
  final Uint8List maxValues;

  void addFrame(Uint8List rgbBytes, {required int dx, required int dy}) {
    final int startX = math.max(0, -dx);
    final int endX = math.min(width, width - dx);
    final int startY = math.max(0, -dy);
    final int endY = math.min(height, height - dy);

    if (startX >= endX || startY >= endY) {
      return;
    }

    for (int y = startY; y < endY; y++) {
      final int destRowOffset = y * width;
      final int srcRowOffset = (y + dy) * width;
      for (int x = startX; x < endX; x++) {
        final int destPixelIndex = destRowOffset + x;
        final int destBase = destPixelIndex * 3;
        final int srcPixelIndex = (srcRowOffset + x + dx) * 3;

        sums[destBase] += rgbBytes[srcPixelIndex];
        sums[destBase + 1] += rgbBytes[srcPixelIndex + 1];
        sums[destBase + 2] += rgbBytes[srcPixelIndex + 2];
        sumSquares[destBase] += rgbBytes[srcPixelIndex] * rgbBytes[srcPixelIndex];
        sumSquares[destBase + 1] +=
            rgbBytes[srcPixelIndex + 1] * rgbBytes[srcPixelIndex + 1];
        sumSquares[destBase + 2] +=
            rgbBytes[srcPixelIndex + 2] * rgbBytes[srcPixelIndex + 2];
        counts[destPixelIndex] += 1;

        if (rgbBytes[srcPixelIndex] > maxValues[destBase]) {
          maxValues[destBase] = rgbBytes[srcPixelIndex];
        }
        if (rgbBytes[srcPixelIndex + 1] > maxValues[destBase + 1]) {
          maxValues[destBase + 1] = rgbBytes[srcPixelIndex + 1];
        }
        if (rgbBytes[srcPixelIndex + 2] > maxValues[destBase + 2]) {
          maxValues[destBase + 2] = rgbBytes[srcPixelIndex + 2];
        }
      }
    }
  }
}

class _FinalizeNightImageRequest {
  const _FinalizeNightImageRequest({
    required this.sums,
    required this.sumSquares,
    required this.counts,
    required this.reference,
    required this.maxValues,
    required this.width,
    required this.height,
    required this.starEnhance,
  });

  final Float64List sums;
  final Float64List sumSquares;
  final Int32List counts;
  final Uint8List reference;
  final Uint8List maxValues;
  final int width;
  final int height;
  final bool starEnhance;
}

Uint8List _finalizeNightImage(_FinalizeNightImageRequest request) {
  final int pixelCount = request.width * request.height;
  final Uint8List toned = Uint8List(pixelCount * 3);

  for (int i = 0; i < pixelCount; i++) {
    final int base = i * 3;
    final int count = request.counts[i];

    double r;
    double g;
    double b;
    double rStd = 0;
    double gStd = 0;
    double bStd = 0;

    if (count == 0) {
      r = request.reference[base].toDouble();
      g = request.reference[base + 1].toDouble();
      b = request.reference[base + 2].toDouble();
    } else {
      r = request.sums[base] / count;
      g = request.sums[base + 1] / count;
      b = request.sums[base + 2] / count;

      rStd = _channelStdDev(request.sums[base], request.sumSquares[base], count);
      gStd = _channelStdDev(
        request.sums[base + 1],
        request.sumSquares[base + 1],
        count,
      );
      bStd = _channelStdDev(
        request.sums[base + 2],
        request.sumSquares[base + 2],
        count,
      );
    }

    if (request.starEnhance) {
      r = _highlightBlend(
        r,
        request.maxValues[base].toDouble(),
        rStd,
      );
      g = _highlightBlend(
        g,
        request.maxValues[base + 1].toDouble(),
        gStd,
      );
      b = _highlightBlend(
        b,
        request.maxValues[base + 2].toDouble(),
        bStd,
      );
    }

    final double luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if (luminance < 38) {
      final double lift = (38 - luminance) * 0.45;
      r += lift;
      g += lift * 0.92;
      b += lift * 1.05;
    }

    toned[base] = _toneMapChannel(r);
    toned[base + 1] = _toneMapChannel(g);
    toned[base + 2] = _toneMapChannel(b);
  }

  _applyUnsharpMask(toned, request.width, request.height, amount: 0.4);

  if (request.starEnhance) {
    _applyColorBalance(toned, request.width, request.height);
  }

  final img.Image image = img.Image.fromBytes(
    width: request.width,
    height: request.height,
    bytes: toned.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );

  return Uint8List.fromList(img.encodeJpg(image, quality: 94));
}

int _toneMapChannel(double value) {
  double normalized = (value / 255.0).clamp(0.0, 1.0);
  normalized *= 1.35;
  normalized = normalized / (1 + normalized * 0.6);
  normalized = math.pow(normalized, 0.85).toDouble();
  normalized = normalized.clamp(0.0, 1.0);
  final int result = (normalized * 255).round();
  if (result < 0) {
    return 0;
  }
  if (result > 255) {
    return 255;
  }
  return result;
}

double _channelStdDev(double sum, double sumSquares, int count) {
  if (count <= 0) {
    return 0;
  }
  final double mean = sum / count;
  final double meanSquares = sumSquares / count;
  final double variance = math.max(0, meanSquares - mean * mean);
  return math.sqrt(variance);
}

double _highlightBlend(double mean, double highlight, double stdDev) {
  final double boost = math.max(0, highlight - mean);
  if (boost == 0) {
    return mean;
  }
  final double stability = stdDev + 8;
  final double weight = (boost / stability).clamp(0.0, 1.0);
  final double mix = 0.18 + weight * 0.55;
  final double enhanced = mean * (1 - mix) + highlight * mix;
  return enhanced.clamp(0.0, 255.0);
}

void _applyColorBalance(Uint8List data, int width, int height) {
  final int pixelCount = width * height;
  for (int i = 0; i < pixelCount; i++) {
    final int base = i * 3;
    double r = data[base].toDouble();
    double g = data[base + 1].toDouble();
    double b = data[base + 2].toDouble();

    // Cool the white balance slightly to emphasize night skies.
    r *= 0.96;
    g *= 1.02;
    b *= 1.05;

    final double luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if (luminance < 70) {
      final double saturationBoost = (70 - luminance) / 140;
      final double avg = (r + g + b) / 3;
      r = r + (avg - r) * saturationBoost * -0.15;
      g = g + (avg - g) * saturationBoost * -0.05;
      b = b + (avg - b) * saturationBoost * -0.2;
    }

    data[base] = _clampToByte(r);
    data[base + 1] = _clampToByte(g);
    data[base + 2] = _clampToByte(b);
  }
}

int _clampToByte(double value) {
  if (value <= 0) {
    return 0;
  }
  if (value >= 255) {
    return 255;
  }
  return value.round();
}

void _applyUnsharpMask(Uint8List data, int width, int height,
    {double amount = 0.5}) {
  if (amount <= 0) {
    return;
  }
  final Uint8List blurred = _boxBlur3x3(data, width, height);
  for (int i = 0; i < data.length; i++) {
    final double original = data[i].toDouble();
    final double blur = blurred[i].toDouble();
    final double value = original + amount * (original - blur);
    data[i] = value.clamp(0, 255).round();
  }
}

Uint8List _boxBlur3x3(Uint8List data, int width, int height) {
  final Uint8List output = Uint8List(data.length);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      double sumR = 0;
      double sumG = 0;
      double sumB = 0;
      int samples = 0;

      for (int ky = -1; ky <= 1; ky++) {
        final int sy = y + ky;
        if (sy < 0 || sy >= height) {
          continue;
        }
        for (int kx = -1; kx <= 1; kx++) {
          final int sx = x + kx;
          if (sx < 0 || sx >= width) {
            continue;
          }
          final int sampleIndex = (sy * width + sx) * 3;
          sumR += data[sampleIndex];
          sumG += data[sampleIndex + 1];
          sumB += data[sampleIndex + 2];
          samples++;
        }
      }

      final double inv = 1.0 / samples;
      final int destIndex = (y * width + x) * 3;
        final int r = (sumR * inv).round();
        final int g = (sumG * inv).round();
        final int b = (sumB * inv).round();
        output[destIndex] = r < 0
          ? 0
          : (r > 255
            ? 255
            : r);
        output[destIndex + 1] = g < 0
          ? 0
          : (g > 255
            ? 255
            : g);
        output[destIndex + 2] = b < 0
          ? 0
          : (b > 255
            ? 255
            : b);
    }
  }

  return output;
}
