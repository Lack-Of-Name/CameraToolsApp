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

enum _AdjustmentKind {
  duration,
  fps,
  focus,
  autoIso,
  manualExposure,
  starEnhance,
}

class _CameraHomeState extends State<CameraHome> {
  static const int _maxFrameCount = 180;
  static const double _fastShutterBias = -1.5;
  static const double _minDurationSeconds = 3;
  static const double _maxDurationSeconds = 20;
  static const double _minFramesPerSecond = 3;
  static const double _maxFramesPerSecond = 10;
  static const double _minAutoIsoBias = -2;
  static const double _maxAutoIsoBias = 2;
  static const double _defaultAutoIsoBias = -0.25;

  // Shared palette for the refreshed UI.
  static const Color _accentColor = Color(0xFF4EE3FF);
  static const Color _accentMuted = Color(0xFF1BA7BA);
  static const Color _panelColor = Color(0xFF15131F);
  static const Color _chipBorderColor = Color(0x33FFFFFF);
  static final WidgetStateProperty<Color?> _switchThumbColor =
      WidgetStateProperty.resolveWith<Color?>((states) {
    return states.contains(WidgetState.selected) ? Colors.black : Colors.white60;
  });
  static final WidgetStateProperty<Color?> _switchTrackColor =
      WidgetStateProperty.resolveWith<Color?>((states) {
    return states.contains(WidgetState.selected) ? _accentColor : Colors.white24;
  });

  CameraController? _controller;
  CameraDescription? _activeCamera;
  bool _isCapturing = false;
  double _progress = 0;
  String? _status;
  String? _lastSavedPath;
  Uint8List? _lastSavedImageBytes;

  double _captureDurationSeconds = 12;
  double _captureFramesPerSecond = 6;
  double _focusDepth = 0.5;
  bool _focusSupported = false;
  bool _autoFocusEnabled = true;
  bool _starEnhance = true;
  bool _flashAllowed = false;
  bool _autoIsoEnabled = false;
  double _autoIsoBias = _defaultAutoIsoBias;
  bool _manualExposureEnabled = false;
  double _manualExposureOffset = 0;
  double _minExposureOffset = -2;
  double _maxExposureOffset = 2;
  _AdjustmentKind? _activeAdjustment;
  bool _adjustmentsExpanded = false;
  bool _showThirdsOverlay = false;

  Timer? _focusDebounce;

  int get _plannedFrameCount =>
      math.max(1, (_captureDurationSeconds * _captureFramesPerSecond).round());

  int get _targetFrameCount => math.min(_plannedFrameCount, _maxFrameCount);

  bool get _isFrameCountClamped => _plannedFrameCount > _maxFrameCount;

  bool get _exposureAdjustable => _maxExposureOffset > _minExposureOffset + 0.0001;

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

  Future<void> _setFlashAllowed(bool value) async {
    if (_isCapturing) {
      return;
    }
    setState(() {
      _flashAllowed = value;
    });

    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      await controller.setFlashMode(value ? FlashMode.auto : FlashMode.off);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _flashAllowed = !value;
        _status = 'Failed to update flash: $error';
      });
    }
  }

  Future<void> _setAutoIsoEnabled(bool value) async {
    if (_isCapturing) {
      return;
    }

    setState(() {
      _autoIsoEnabled = value;
      if (value) {
        _manualExposureEnabled = false;
      }
    });

    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      if (value) {
        final double clampedBias =
            _autoIsoBias.clamp(_minExposureOffset, _maxExposureOffset);
        _autoIsoBias = clampedBias;
        await controller.setExposureMode(ExposureMode.auto);
        await controller.setExposureOffset(clampedBias);
      } else if (_manualExposureEnabled) {
        final double clamped =
            _manualExposureOffset.clamp(_minExposureOffset, _maxExposureOffset);
        await controller.setExposureMode(ExposureMode.locked);
        await controller.setExposureOffset(clamped);
      } else {
        await controller.setExposureMode(ExposureMode.auto);
        await controller.setExposureOffset(_fastShutterBias);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Auto ISO update failed: $error';
      });
    }
  }

  Future<void> _setManualExposureEnabled(bool value) async {
    if (_isCapturing) {
      return;
    }
    if (_maxExposureOffset <= _minExposureOffset + 0.0001) {
      setState(() {
        _manualExposureEnabled = false;
      });
      return;
    }
    setState(() {
      _manualExposureEnabled = value;
      if (value) {
        _autoIsoEnabled = false;
      }
    });

    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      if (value) {
        final double clamped =
            _manualExposureOffset.clamp(_minExposureOffset, _maxExposureOffset);
        _manualExposureOffset = clamped;
        await controller.setExposureMode(ExposureMode.locked);
        await controller.setExposureOffset(clamped);
      } else {
        await controller.setExposureMode(ExposureMode.auto);
        await controller.setExposureOffset(0);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _manualExposureEnabled = !value;
        _status = 'Manual exposure failed: $error';
      });
    }
  }

  Future<void> _setAutoIsoBias(double value) async {
    final double clamped = value.clamp(
      math.max(_minExposureOffset, _minAutoIsoBias),
      math.min(_maxExposureOffset, _maxAutoIsoBias),
    );
    setState(() {
      _autoIsoBias = clamped;
    });

    if (!_autoIsoEnabled) {
      return;
    }

    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      await controller.setExposureOffset(clamped);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Auto ISO bias failed: $error';
      });
    }
  }

  Future<void> _setManualExposureOffset(double value) async {
    if (_maxExposureOffset <= _minExposureOffset + 0.0001) {
      return;
    }
    final double clamped = value.clamp(_minExposureOffset, _maxExposureOffset);
    setState(() {
      _manualExposureOffset = clamped;
    });

    if (!_manualExposureEnabled) {
      return;
    }

    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      await controller.setExposureOffset(clamped);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Exposure offset failed: $error';
      });
    }
  }

  Future<void> _applyCurrentFlashPreference(CameraController controller) async {
    try {
      await controller.setFlashMode(_flashAllowed ? FlashMode.auto : FlashMode.off);
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Flash sync failed: $error';
        });
      }
    }
  }

  Future<void> _applyCurrentExposurePreference(CameraController controller) async {
    try {
      if (_manualExposureEnabled) {
        final double clamped =
            _manualExposureOffset.clamp(_minExposureOffset, _maxExposureOffset);
        await controller.setExposureMode(ExposureMode.locked);
        await controller.setExposureOffset(clamped);
      } else if (_autoIsoEnabled) {
        final double clamped =
            _autoIsoBias.clamp(_minExposureOffset, _maxExposureOffset);
        _autoIsoBias = clamped;
        await controller.setExposureMode(ExposureMode.auto);
        await controller.setExposureOffset(clamped);
      } else {
        await controller.setExposureMode(ExposureMode.auto);
        await controller.setExposureOffset(_fastShutterBias);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Exposure sync failed: $error';
        });
      }
    }
  }

  Future<void> _refreshExposureBounds(CameraController controller) async {
    try {
      final double minOffset = await controller.getMinExposureOffset();
      final double maxOffset = await controller.getMaxExposureOffset();
      if (!mounted) {
        return;
      }
      setState(() {
        _minExposureOffset = minOffset;
        _maxExposureOffset = maxOffset;
        _manualExposureOffset =
            _manualExposureOffset.clamp(minOffset, maxOffset);
        _autoIsoBias = _autoIsoBias.clamp(minOffset, maxOffset);
        if (_maxExposureOffset <= _minExposureOffset + 0.0001) {
          _manualExposureEnabled = false;
          _autoIsoEnabled = false;
        }
      });
    } catch (_) {
      // Some devices may not report manual bounds; keep defaults.
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
        bool flashTemp = _flashAllowed;

        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 24,
                bottom: 16 + MediaQuery.of(sheetContext).padding.bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Capture settings',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      decoration: BoxDecoration(
                        color: _panelColor.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _chipBorderColor, width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Allow flash',
                                  style: TextStyle(color: Colors.white)),
                              Switch.adaptive(
                                value: flashTemp,
                                thumbColor: _switchThumbColor,
                                trackColor: _switchTrackColor,
                                onChanged: _isCapturing
                                    ? null
                                    : (value) {
                                        setSheetState(() => flashTemp = value);
                                        _setFlashAllowed(value);
                                      },
                              ),
                            ],
                          ),
                          const Text(
                            'Leave this off for dark-sky shoots so the flash never triggers unexpectedly.',
                            style: TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Use the adjustments menu on the top right for capture planning, focus, ISO bias, manual EV, and thirds overlays.',
                      style: const TextStyle(color: Colors.white54, height: 1.3),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'NightPlus captures up to $_maxFrameCount frames. Combine manual EV with the capture planner for the best blend of detail and low noise.',
                      style: const TextStyle(color: Colors.white54, height: 1.3),
                    ),
                  ],
                ),
              ),
            );
          },
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

      await _refreshExposureBounds(controller);

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

      await _applyCurrentFlashPreference(controller);
      await _applyCurrentExposurePreference(controller);
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

    final bool manualExposure = _manualExposureEnabled;
    final bool autoIsoActive = _autoIsoEnabled;
    final double manualOffset =
        _manualExposureOffset.clamp(_minExposureOffset, _maxExposureOffset);
    double autoIsoBias =
        _autoIsoBias.clamp(_minExposureOffset, _maxExposureOffset);
    final bool flashAllowed = _flashAllowed;

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
        await controller.setFlashMode(flashAllowed ? FlashMode.auto : FlashMode.off);
      } catch (error) {
        if (mounted) {
          setState(() {
            _status = 'Flash disabled for capture (reason: $error)';
          });
        }
      }

      try {
        if (manualExposure) {
          await controller.setExposureMode(ExposureMode.locked);
          await controller.setExposureOffset(manualOffset);
        } else if (autoIsoActive) {
          await controller.setExposureMode(ExposureMode.auto);
          await controller.setExposureOffset(autoIsoBias);
        } else {
          await controller.setExposureMode(ExposureMode.auto);
          await controller.setExposureOffset(_fastShutterBias);
        }
      } on CameraException {
        // Continue even if exposure adjustments are not available.
      }

      while (capturedFrames < targetFrames) {
        frameStopwatch
          ..reset()
          ..start();

        final XFile capture = await controller.takePicture();
        final Uint8List bytes = await capture.readAsBytes();
        capturedBytes.add(bytes);
        capturedFrames++;

        if (autoIsoActive && capturedFrames < targetFrames) {
          final double luminance = _estimateAverageLuminance(bytes);
          const double targetLuma = 58;
          const double tolerance = 6;
          double adjustment = 0;
          if (luminance < targetLuma - tolerance) {
            adjustment = 0.12;
          } else if (luminance > targetLuma + tolerance) {
            adjustment = -0.12;
          }

          if (adjustment != 0) {
            autoIsoBias = (autoIsoBias + adjustment)
                .clamp(_minExposureOffset, _maxExposureOffset);
            try {
              await controller.setExposureOffset(autoIsoBias);
            } catch (_) {
              // Ignore inability to adjust between frames.
            }
          }
        }

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

      if (autoIsoActive && mounted) {
        setState(() {
          _autoIsoBias = autoIsoBias;
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

      final Uint8List finalBytes = processed.jpegBytes;
      final savedLocation =
          await saveProcessedPhotoBytes(finalBytes, 'jpg');

      if (mounted) {
        setState(() {
          _lastSavedImageBytes = finalBytes;
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
        if (manualExposure) {
          await controller.setExposureMode(ExposureMode.locked);
          await controller.setExposureOffset(manualOffset);
        } else if (autoIsoActive) {
          await controller.setExposureMode(ExposureMode.auto);
          await controller.setExposureOffset(autoIsoBias);
        } else {
          await controller.setExposureMode(ExposureMode.auto);
          await controller.setExposureOffset(_fastShutterBias);
        }
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

  double _estimateAverageLuminance(Uint8List jpegBytes) {
    try {
      final img.Image? decoded = img.decodeImage(jpegBytes);
      if (decoded == null) {
        return 0;
      }

      img.Image sample = decoded;
      if (decoded.width > 160 || decoded.height > 160) {
        sample = img.copyResize(
          decoded,
          width: 160,
          height: 160,
          interpolation: img.Interpolation.average,
        );
      }

      final Uint8List bytes = Uint8List.fromList(sample.getBytes());
      final int channels = sample.numChannels;
      if (channels < 3) {
        return 0;
      }

      double luminanceSum = 0;
      final int pixelCount = bytes.length ~/ channels;
      for (int i = 0; i < pixelCount; i++) {
        final int offset = i * channels;
        final double r = bytes[offset].toDouble();
        final double g = bytes[offset + 1].toDouble();
        final double b = bytes[offset + 2].toDouble();
        luminanceSum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
      }

      return luminanceSum / pixelCount;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildInitializationState(),
      );
    }

    final Orientation orientation = MediaQuery.of(context).orientation;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildCameraSurface(context, controller)),
          if (_showThirdsOverlay)
            const Positioned.fill(
              child: IgnorePointer(child: _RuleOfThirdsOverlay()),
            ),
          Align(
            alignment: Alignment.topCenter,
            child: _buildTopChrome(context),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _buildBottomChrome(context, orientation),
          ),
          Positioned.fill(child: _buildAdjustmentsTray(context)),
          if (_activeAdjustment != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _activeAdjustment = null),
                child: const SizedBox.shrink(),
              ),
            ),
          if (_activeAdjustment != null)
            _buildAdjustmentPanel(context),
          if (_isCapturing)
            Positioned.fill(
              child: AbsorbPointer(
                child: _buildProgressOverlay(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInitializationState() {
    final String? message = _status;
    if (message != null && message.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return const Center(
      child: CircularProgressIndicator(),
    );
  }

  Widget _buildCameraSurface(BuildContext context, CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null || previewSize.height == 0) {
      return const ColoredBox(color: Colors.black);
    }
    if (previewSize.width == 0 || previewSize.height == 0) {
      return const ColoredBox(color: Colors.black);
    }

    final Orientation orientation = MediaQuery.of(context).orientation;
    final bool isPortrait = orientation == Orientation.portrait;
    final double displayWidth = isPortrait ? previewSize.height : previewSize.width;
    final double displayHeight = isPortrait ? previewSize.width : previewSize.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: displayWidth,
              height: displayHeight,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopChrome(BuildContext context) {
    final String statusLabel = (_status ?? 'Ready').toUpperCase();

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: SizedBox(
          height: 54,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: _buildSettingsButton(),
              ),
              Align(
                alignment: Alignment.center,
                child: _buildStatusChip(statusLabel),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: _buildAdjustmentsToggle(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _chipBorderColor),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.05,
        ),
      ),
    );
  }

  Widget _buildSettingsButton() {
    return _topChromeButton(
      icon: Icons.settings_outlined,
      onPressed: _isCapturing ? null : _openSettingsSheet,
    );
  }

  Widget _buildAdjustmentsToggle() {
    return _topChromeButton(
      icon: _adjustmentsExpanded ? Icons.close_fullscreen : Icons.tune,
      highlight: _adjustmentsExpanded,
      onPressed: () {
        setState(() {
          _adjustmentsExpanded = !_adjustmentsExpanded;
          if (!_adjustmentsExpanded) {
            _activeAdjustment = null;
          }
        });
      },
    );
  }

  Widget _topChromeButton({
    required IconData icon,
    VoidCallback? onPressed,
    bool highlight = false,
  }) {
    final bool enabled = onPressed != null;
    final Color background = highlight
        ? _accentColor.withValues(alpha: 0.25)
        : Colors.black.withValues(alpha: 0.35);
    final Color iconColor = highlight
        ? _accentColor
        : enabled
            ? Colors.white
            : Colors.white24;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: iconColor, size: 22),
        ),
      ),
    );
  }

  Widget _buildBottomChrome(BuildContext context, Orientation orientation) {
    final double bottomPadding = MediaQuery.of(context).padding.bottom;
    final bool isLandscape = orientation == Orientation.landscape;
    final double horizontalPadding = isLandscape ? 32 : 24;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        padding:
            EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, bottomPadding + 24),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
            stops: [0, 1],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCaptureSummaryRow(),
            const SizedBox(height: 16),
            _buildPrimaryCaptureControls(context),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureSummaryRow() {
    final int frameCount = _targetFrameCount;
    final double duration = _captureDurationSeconds;
    final double fps = _captureFramesPerSecond;
    final bool manual = _manualExposureEnabled;
    final bool autoIso = _autoIsoEnabled;
    final double evStops = manual
      ? _manualExposureOffset
      : autoIso
        ? _autoIsoBias
        : _fastShutterBias;
    final int isoEstimate = _estimateIsoFromEv(evStops);
    final String focusLabel = _autoFocusEnabled
        ? 'AF'
        : 'MF ${(100 * _focusDepth).clamp(0, 100).toStringAsFixed(0)}%';
    final String exposureLabel = manual
      ? 'Manual ${_manualExposureOffset.toStringAsFixed(1)} EV'
      : autoIso
        ? 'Auto ISO ${_autoIsoBias.toStringAsFixed(1)}'
        : (_flashAllowed ? 'Flash auto' : 'Fast shutter');
    final String isoLabel = 'ISO $isoEstimate';

    final List<Widget> pills = [
      _buildSummaryPill('${duration.toStringAsFixed(1)} s'),
      _buildSummaryPill('${fps.toStringAsFixed(1)} fps'),
      _buildSummaryPill('$frameCount frames'),
      _buildSummaryPill(focusLabel),
      _buildSummaryPill(exposureLabel),
      _buildSummaryPill(isoLabel),
    ];

    if (_lastSavedPath != null) {
      pills.add(_buildSummaryPill('Saved to Photos'));
    }

    return Wrap(
      spacing: 10,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: pills,
    );
  }

  Widget _buildSummaryPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _chipBorderColor),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _buildAdjustmentIconButton({
    required IconData icon,
    required String label,
    required bool active,
    required bool enabled,
    required VoidCallback? onTap,
  }) {
    final Color iconColor = active ? _accentColor : Colors.white;
    final Color background = active
        ? _accentColor.withValues(alpha: 0.2)
        : Colors.black.withValues(alpha: 0.35);

    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: background,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: enabled ? onTap : null,
                splashColor: _accentColor.withValues(alpha: 0.2),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdjustmentsTray(BuildContext context) {
    final bool expanded = _adjustmentsExpanded;
    if (!expanded) {
      return const SizedBox.shrink();
    }

    final bool focusAvailable = _focusSupported;
    final bool exposureAdjustable = _exposureAdjustable;

    Widget buildKindButton({
      required IconData icon,
      required String label,
      required _AdjustmentKind kind,
      bool enabled = true,
    }) {
      final bool isActive = _activeAdjustment == kind;
      final bool effectiveEnabled = enabled && !_isCapturing;
      return _buildAdjustmentIconButton(
        icon: icon,
        label: label,
        active: isActive,
        enabled: effectiveEnabled,
        onTap: effectiveEnabled
            ? () {
                setState(() {
                  _activeAdjustment = isActive ? null : kind;
                });
              }
            : null,
      );
    }

    final List<Widget> buttons = [
      buildKindButton(
        icon: Icons.timelapse,
        label: 'Duration',
        kind: _AdjustmentKind.duration,
      ),
      buildKindButton(
        icon: Icons.graphic_eq,
        label: 'FPS',
        kind: _AdjustmentKind.fps,
      ),
      buildKindButton(
        icon: Icons.center_focus_weak,
        label: 'Focus',
        kind: _AdjustmentKind.focus,
        enabled: focusAvailable,
      ),
      buildKindButton(
        icon: Icons.blur_on,
        label: 'Auto ISO',
        kind: _AdjustmentKind.autoIso,
        enabled: exposureAdjustable,
      ),
      buildKindButton(
        icon: Icons.tune,
        label: 'Manual EV',
        kind: _AdjustmentKind.manualExposure,
        enabled: exposureAdjustable,
      ),
      buildKindButton(
        icon: Icons.auto_awesome,
        label: 'Stars',
        kind: _AdjustmentKind.starEnhance,
      ),
      _buildAdjustmentIconButton(
        icon: _showThirdsOverlay ? Icons.grid_off : Icons.grid_on,
        label: _showThirdsOverlay ? 'Hide grid' : 'Thirds',
        active: _showThirdsOverlay,
        enabled: true,
        onTap: () {
          setState(() {
            _showThirdsOverlay = !_showThirdsOverlay;
          });
        },
      ),
    ];

    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 64, right: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _panelColor.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: _chipBorderColor),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 24,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick controls',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 12,
                    children: buttons,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAdjustmentPanel(BuildContext context) {
    final _AdjustmentKind? active = _activeAdjustment;
    if (active == null) {
      return const SizedBox.shrink();
    }

    String title;
    Widget body;
    switch (active) {
      case _AdjustmentKind.duration:
      case _AdjustmentKind.fps:
        title = 'Capture planner';
        body = _buildCapturePlanner();
        break;
      case _AdjustmentKind.focus:
        title = 'Focus';
        body = _buildFocusControls();
        break;
      case _AdjustmentKind.autoIso:
        title = 'Auto ISO bias';
        body = _buildAutoIsoControls(context);
        break;
      case _AdjustmentKind.manualExposure:
        title = 'Manual exposure';
        body = _buildManualExposureControls(context);
        break;
      case _AdjustmentKind.starEnhance:
        title = 'Star highlight boost';
        body = _buildStarEnhanceControls();
        break;
    }

    final double bottomPadding = MediaQuery.of(context).padding.bottom;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding + 16),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 16),
            decoration: BoxDecoration(
              color: _panelColor.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: _chipBorderColor),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black87,
                  blurRadius: 28,
                  offset: Offset(0, 18),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => setState(() => _activeAdjustment = null),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                body,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFocusControls() {
    if (!_focusSupported) {
      return const Text(
        'This camera does not expose manual focus controls.',
        style: TextStyle(color: Colors.white54),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAutoFocusToggle(),
        const SizedBox(height: 12),
        if (!_autoFocusEnabled) ...[
          _buildFocusSlider(),
          const SizedBox(height: 8),
        ] else
          const SizedBox(height: 8),
        const Text(
          'Switch to manual to pull focus toward infinity or a nearby subject.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildAutoIsoControls(BuildContext context) {
    final bool adjustable = _exposureAdjustable;
    final double minBias = math.max(_minExposureOffset, _minAutoIsoBias);
    final double maxBias = math.min(_maxExposureOffset, _maxAutoIsoBias);
    final double value = _autoIsoBias.clamp(minBias, maxBias);
    final String label = value >= 0 ? '+${value.toStringAsFixed(1)} EV' : '${value.toStringAsFixed(1)} EV';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Enable auto ISO', style: TextStyle(color: Colors.white)),
            Switch.adaptive(
              value: _autoIsoEnabled,
              thumbColor: _switchThumbColor,
              trackColor: _switchTrackColor,
              onChanged:
                  (_isCapturing || !adjustable) ? null : (value) => _setAutoIsoEnabled(value),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          adjustable
              ? 'Let NightPlus trim or boost ISO between frames for steadier light.'
              : 'This lens does not expose EV adjustments.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 12),
        SliderTheme(
          data: _sliderTheme(context),
          child: Slider(
            value: value,
            min: minBias,
            max: maxBias,
            divisions: adjustable
                ? math.max(1, ((maxBias - minBias) * 10).round())
                : 1,
            label: label,
            onChanged: (_autoIsoEnabled && adjustable && !_isCapturing)
                ? (next) => _setAutoIsoBias(next)
                : null,
          ),
        ),
        Text(
          _autoIsoEnabled
              ? 'Bias $label. Negative favors cleaner frames, positive leans brighter.'
              : 'Enable auto ISO to tune the bias.',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildManualExposureControls(BuildContext context) {
    final bool adjustable = _exposureAdjustable;
    final double value = _manualExposureOffset.clamp(_minExposureOffset, _maxExposureOffset);
    final String label = value >= 0 ? '+${value.toStringAsFixed(1)} EV' : '${value.toStringAsFixed(1)} EV';
    final int isoEstimate = _estimateIsoFromEv(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Enable manual EV', style: TextStyle(color: Colors.white)),
            Switch.adaptive(
              value: _manualExposureEnabled,
              thumbColor: _switchThumbColor,
              trackColor: _switchTrackColor,
              onChanged:
                  (_isCapturing || !adjustable) ? null : (value) => _setManualExposureEnabled(value),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          adjustable
              ? 'Lock exposure compensation to hold brightness across the stack.'
              : 'This lens does not expose manual EV controls.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 12),
        SliderTheme(
          data: _sliderTheme(context),
          child: Slider(
            value: value,
            min: _minExposureOffset,
            max: _maxExposureOffset,
            divisions: adjustable
                ? math.max(1, ((_maxExposureOffset - _minExposureOffset) * 10).round())
                : 1,
            label: label,
            onChanged: (_manualExposureEnabled && adjustable && !_isCapturing)
                ? (next) => _setManualExposureOffset(next)
                : null,
          ),
        ),
        Text(
          _manualExposureEnabled
              ? 'EV $label · approx ISO $isoEstimate.'
              : 'Enable manual EV to drag this slider.',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildStarEnhanceControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Star highlight boost', style: TextStyle(color: Colors.white)),
            Switch.adaptive(
              value: _starEnhance,
              thumbColor: _switchThumbColor,
              trackColor: _switchTrackColor,
              onChanged: _isCapturing ? null : _setStarEnhance,
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Keeps the brightest pinpoints from the stack while lifting deep shadows.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  int _estimateIsoFromEv(double ev) {
    final double iso = 100 * math.pow(2.0, ev).toDouble();
    final double clamped = iso.clamp(25.0, 12800.0);
    return clamped.round();
  }

  SliderThemeData _sliderTheme(BuildContext context) {
    final SliderThemeData base = SliderTheme.of(context);
    return base.copyWith(
      trackHeight: 3.2,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      activeTrackColor: _accentColor,
      inactiveTrackColor: Colors.white12,
      thumbColor: _accentColor,
      overlayColor: _accentColor.withValues(alpha: 0.2),
      valueIndicatorColor: _panelColor,
      activeTickMarkColor: Colors.white24,
      inactiveTickMarkColor: Colors.white10,
    );
  }

  Widget _buildPresetChip({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final bool disabled = onTap == null;
    final Color background = selected
        ? _accentColor.withValues(alpha: 0.18)
        : _panelColor.withValues(alpha: 0.7);
    final Color borderColor = selected ? _accentColor : _chipBorderColor;
    final Color textColor = selected ? Colors.white : Colors.white70;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: disabled ? 0.45 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          splashColor: _accentColor.withValues(alpha: 0.2),
          highlightColor: _accentColor.withValues(alpha: 0.1),
          onTap: disabled ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: textColor,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryCaptureControls(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildPreviewButton(),
          _buildCaptureButton(context),
          Container(
            decoration: BoxDecoration(
              color: _panelColor.withValues(alpha: _isCapturing ? 0.4 : 0.85),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _chipBorderColor, width: 1),
            ),
            child: IconButton(
              iconSize: 28,
              splashRadius: 24,
              color: _isCapturing ? Colors.white38 : _accentColor,
              onPressed:
                  _isCapturing || widget.cameras.length < 2 ? null : _switchCamera,
              icon: const Icon(Icons.cameraswitch),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewButton() {
    final Uint8List? previewBytes = _lastSavedImageBytes;
    return GestureDetector(
      onTap: _openRecentPhotoEditor,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _chipBorderColor, width: 1.5),
          color: _panelColor.withValues(alpha: 0.85),
        ),
        clipBehavior: Clip.hardEdge,
        child: previewBytes != null
            ? Image.memory(
                previewBytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            : const Center(
                child: Icon(
                  Icons.photo_library_outlined,
                  color: _accentColor,
                ),
              ),
      ),
    );
  }

  Future<void> _openRecentPhotoEditor() async {
    if (_lastSavedImageBytes == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capture a photo to review it.')),
      );
      return;
    }

    final _EditedPhotoResult? edited = await Navigator.of(context)
        .push<_EditedPhotoResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (routeContext) => RecentPhotoEditor(
          imageBytes: _lastSavedImageBytes!,
        ),
      ),
    );

    if (!mounted || edited == null) {
      return;
    }

    setState(() {
      _lastSavedImageBytes = edited.bytes;
      _lastSavedPath = edited.savedPath;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Edited copy saved to Photos')),
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
    final double effectiveSeconds = targetFrames / fpsValue;
    final Iterable<double> durationPresets = const <double>[3, 6, 12, 20]
      .where((value) => value >= _minDurationSeconds && value <= _maxDurationSeconds);
    final Iterable<double> fpsPresets = const <double>[3, 4, 6, 8, 10]
      .where((value) => value >= _minFramesPerSecond && value <= _maxFramesPerSecond);

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
        SliderTheme(
          data: _sliderTheme(context),
          child: Slider(
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
        ),
        if (durationPresets.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: durationPresets
                .map(
                  (preset) {
                    final bool selected = (durationValue - preset).abs() < 0.25;
                    return _buildPresetChip(
                      label: '${preset.toStringAsFixed(0)} s',
                      selected: selected,
                      onTap: _isCapturing
                          ? null
                          : () {
                              setState(() {
                                _captureDurationSeconds = preset;
                              });
                            },
                    );
                  },
                )
                .toList(),
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
        SliderTheme(
          data: _sliderTheme(context),
          child: Slider(
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
        ),
        if (fpsPresets.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: fpsPresets
                .map(
                  (preset) {
                    final bool selected = (fpsValue - preset).abs() < 0.25;
                    return _buildPresetChip(
                      label: '${preset.toStringAsFixed(0)} fps',
                      selected: selected,
                      onTap: _isCapturing
                          ? null
                          : () {
                              setState(() {
                                _captureFramesPerSecond = preset;
                              });
                            },
                    );
                  },
                )
                .toList(),
          ),
        const SizedBox(height: 12),
        Text(
          framesLabel,
          style: const TextStyle(color: Colors.white70),
        ),
        Text(
          'Stack time ≈ ${effectiveSeconds.toStringAsFixed(1)} s • Frame gap ${frameIntervalMs.toStringAsFixed(0)} ms',
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
              thumbColor: _switchThumbColor,
              trackColor: _switchTrackColor,
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
        SliderTheme(
          data: _sliderTheme(context),
          child: Slider(
            value: _focusDepth,
            min: 0,
            max: 1,
            onChanged: _isCapturing ? null : _changeFocus,
          ),
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
          thumbColor: _switchThumbColor,
          trackColor: _switchTrackColor,
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
          border: Border.all(
            color: _accentColor.withValues(alpha: _isCapturing ? 0.7 : 0.4),
            width: 4,
          ),
          color: _panelColor.withValues(alpha: 0.8),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isCapturing ? _accentMuted : Colors.white,
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

class _RuleOfThirdsOverlay extends StatelessWidget {
  const _RuleOfThirdsOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ThirdsPainter(Theme.of(context).colorScheme.primary),
    );
  }
}

class _ThirdsPainter extends CustomPainter {
  _ThirdsPainter(Color accent)
      : linePaint = Paint()
          ..color = accent.withValues(alpha: 0.25)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke;

  final Paint linePaint;

  @override
  void paint(Canvas canvas, Size size) {
    final double thirdWidth = size.width / 3;
    final double thirdHeight = size.height / 3;

    for (int i = 1; i <= 2; i++) {
      final double dx = thirdWidth * i;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), linePaint);
    }

    for (int i = 1; i <= 2; i++) {
      final double dy = thirdHeight * i;
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ThirdsPainter oldDelegate) {
    return oldDelegate.linePaint.color != linePaint.color;
  }
}

Uint8List _applyPhotoAdjustments(
  Uint8List source,
  double exposureStops,
  double shadowLift,
  double saturationDelta,
) {
  final Uint8List result = Uint8List(source.length);
  final double exposureScale = math.pow(2.0, exposureStops).toDouble();
  final double liftedShadows = shadowLift.clamp(0.0, 1.0);
  final double saturationFactor = 1.0 + saturationDelta;

  for (int i = 0; i < source.length; i += 3) {
    double r = source[i].toDouble() * exposureScale;
    double g = source[i + 1].toDouble() * exposureScale;
    double b = source[i + 2].toDouble() * exposureScale;

    final double luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
    if (liftedShadows > 0) {
      final double lift = liftedShadows * (1.0 - math.pow(luminance, 0.6));
      r += 255.0 * lift * 0.9;
      g += 255.0 * lift;
      b += 255.0 * lift * 1.05;
    }

    if (saturationDelta != 0) {
      final double avg = (r + g + b) / 3.0;
      r = avg + (r - avg) * saturationFactor;
      g = avg + (g - avg) * saturationFactor;
      b = avg + (b - avg) * saturationFactor;
    }

    result[i] = _clampToByte(r);
    result[i + 1] = _clampToByte(g);
    result[i + 2] = _clampToByte(b);
  }

  return result;
}

class _EditedPhotoResult {
  const _EditedPhotoResult({required this.bytes, required this.savedPath});

  final Uint8List bytes;
  final String savedPath;
}

enum _CropPreset { original, square, fourThree, threeFour, sixteenNine }

class _CropWindow {
  const _CropWindow({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.isFullFrame,
  });

  final int left;
  final int top;
  final int width;
  final int height;
  final bool isFullFrame;
}

// Lightweight editor for tweaking the most recent capture.
class RecentPhotoEditor extends StatefulWidget {
  const RecentPhotoEditor({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<RecentPhotoEditor> createState() => _RecentPhotoEditorState();
}

class _RecentPhotoEditorState extends State<RecentPhotoEditor> {
  Uint8List? _previewJpeg;
  Uint8List? _basePreviewJpeg;
  Uint8List? _previewRgb;
  Uint8List? _fullRgb;

  int _previewWidth = 0;
  int _previewHeight = 0;
  int _fullWidth = 0;
  int _fullHeight = 0;
  double _previewAspect = 1;

  double _exposureStops = 0;
  double _shadowLift = 0;
  double _saturationDelta = 0;

  _CropPreset _cropPreset = _CropPreset.original;
  double _cropZoom = 1.0;
  double _cropCenterX = 0.5;
  double _cropCenterY = 0.5;

  bool _preparing = true;
  bool _isSaving = false;
  String? _error;

  Timer? _previewDebounce;
  bool _renderingPreview = false;
  bool _previewDirty = false;

  bool get _isNeutralAdjustments =>
      _exposureStops.abs() < 0.001 &&
      _shadowLift.abs() < 0.001 &&
      _saturationDelta.abs() < 0.001;

  @override
  void initState() {
    super.initState();
    _prepareImage();
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    super.dispose();
  }

  Future<void> _prepareImage() async {
    try {
      final img.Image? decoded = img.decodeImage(widget.imageBytes);
      if (decoded == null) {
        throw Exception('Unable to decode the captured image.');
      }

      final img.Image rgb = decoded.convert(numChannels: 3);
      _fullWidth = rgb.width;
      _fullHeight = rgb.height;
      _fullRgb = Uint8List.fromList(
        rgb.getBytes(order: img.ChannelOrder.rgb),
      );

      const double previewLimit = 1400;
      img.Image preview = rgb;
      final double longestSide = math.max(rgb.width, rgb.height).toDouble();
      if (longestSide > previewLimit) {
        final double scale = previewLimit / longestSide;
        final int targetWidth = math.max(1, (rgb.width * scale).round());
        final int targetHeight = math.max(1, (rgb.height * scale).round());
        preview = img.copyResize(
          rgb,
          width: targetWidth,
          height: targetHeight,
          interpolation: img.Interpolation.average,
        );
      }

      _previewWidth = preview.width;
      _previewHeight = preview.height;
      _previewRgb = Uint8List.fromList(
        preview.getBytes(order: img.ChannelOrder.rgb),
      );

      _basePreviewJpeg = Uint8List.fromList(
        img.encodeJpg(preview, quality: 92),
      );
      _previewJpeg = _basePreviewJpeg;
      _previewAspect =
          _previewHeight == 0 ? 1 : _previewWidth / _previewHeight;

      if (!mounted) {
        return;
      }
      setState(() {
        _preparing = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$error';
        _preparing = false;
      });
    }
  }

  void _schedulePreview() {
    if (_preparing || _previewRgb == null) {
      return;
    }
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 90), _renderPreview);
  }

  void _renderPreview() {
    if (!mounted || _preparing || _previewRgb == null) {
      return;
    }
    if (_renderingPreview) {
      _previewDirty = true;
      return;
    }
    if (_basePreviewJpeg == null) {
      return;
    }

    _renderingPreview = true;
    do {
      _previewDirty = false;

      final _CropWindow crop = _resolveCropWindow(_previewWidth, _previewHeight);
      Uint8List nextBytes;

      if (_isNeutralAdjustments && crop.isFullFrame) {
        nextBytes = _basePreviewJpeg!;
        final double aspect =
            _previewHeight == 0 ? 1 : _previewWidth / _previewHeight;
        if (mounted) {
          setState(() {
            _previewJpeg = nextBytes;
            _previewAspect = aspect;
          });
        }
        continue;
      }

      final img.Image baseImage = img.Image.fromBytes(
        width: _previewWidth,
        height: _previewHeight,
        bytes: _previewRgb!.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );

      img.Image workingImage = crop.isFullFrame
          ? baseImage
          : img.copyCrop(
              baseImage,
              x: crop.left,
              y: crop.top,
              width: crop.width,
              height: crop.height,
            );

      Uint8List workingBytes = Uint8List.fromList(
        workingImage.getBytes(order: img.ChannelOrder.rgb),
      );

      if (!_isNeutralAdjustments) {
        workingBytes = _applyPhotoAdjustments(
          workingBytes,
          _exposureStops,
          _shadowLift,
          _saturationDelta,
        );
        workingImage = img.Image.fromBytes(
          width: workingImage.width,
          height: workingImage.height,
          bytes: workingBytes.buffer,
          numChannels: 3,
          order: img.ChannelOrder.rgb,
        );
      }

      nextBytes = Uint8List.fromList(
        img.encodeJpg(workingImage, quality: 90),
      );

      if (!mounted) {
        _renderingPreview = false;
        return;
      }

      setState(() {
        _previewJpeg = nextBytes;
        _previewAspect = workingImage.height == 0
            ? 1
            : workingImage.width / workingImage.height;
      });
    } while (_previewDirty);

    _renderingPreview = false;
  }

  void _resetAdjustments() {
    if (_isNeutralAdjustments) {
      return;
    }
    _previewDebounce?.cancel();
    setState(() {
      _exposureStops = 0;
      _shadowLift = 0;
      _saturationDelta = 0;
    });
    _schedulePreview();
  }

  Future<void> _saveEdits() async {
    if (_isSaving || _preparing || _error != null) {
      return;
    }
    final Uint8List? baseFull = _fullRgb;
    if (baseFull == null) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final _CropWindow crop = _resolveCropWindow(_fullWidth, _fullHeight);
      final bool needsCrop = !crop.isFullFrame;
      final bool needsAdjustments = !_isNeutralAdjustments;

      Uint8List encoded;
      if (!needsCrop && !needsAdjustments) {
        encoded = Uint8List.fromList(widget.imageBytes);
      } else {
        img.Image workingImage = img.Image.fromBytes(
          width: _fullWidth,
          height: _fullHeight,
          bytes: baseFull.buffer,
          numChannels: 3,
          order: img.ChannelOrder.rgb,
        );

        if (needsCrop) {
          workingImage = img.copyCrop(
            workingImage,
            x: crop.left,
            y: crop.top,
            width: crop.width,
            height: crop.height,
          );
        }

        if (needsAdjustments) {
          Uint8List workingBytes = Uint8List.fromList(
            workingImage.getBytes(order: img.ChannelOrder.rgb),
          );
          workingBytes = _applyPhotoAdjustments(
            workingBytes,
            _exposureStops,
            _shadowLift,
            _saturationDelta,
          );
          workingImage = img.Image.fromBytes(
            width: workingImage.width,
            height: workingImage.height,
            bytes: workingBytes.buffer,
            numChannels: 3,
            order: img.ChannelOrder.rgb,
          );
        }

        encoded = Uint8List.fromList(img.encodeJpg(workingImage, quality: 96));
      }

      final String savedPath = await saveProcessedPhotoBytes(encoded, 'jpg');
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        _EditedPhotoResult(bytes: encoded, savedPath: savedPath),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $error')),
      );
      setState(() {
        _isSaving = false;
      });
    }
  }

  bool get _hasCustomCrop {
    return _cropPreset != _CropPreset.original ||
        (_cropZoom - 1).abs() > 0.001 ||
        (_cropCenterX - 0.5).abs() > 0.001 ||
        (_cropCenterY - 0.5).abs() > 0.001;
  }

  _CropWindow _resolveCropWindow(int width, int height) {
    if (width <= 0 || height <= 0) {
      return _CropWindow(
        left: 0,
        top: 0,
        width: math.max(1, width),
        height: math.max(1, height),
        isFullFrame: true,
      );
    }

    final double sourceAspect = width / height;
    final double targetAspect = _desiredCropAspect(sourceAspect);
    final double zoom = _cropZoom.clamp(1.0, 5.0);

    double cropWidth;
    double cropHeight;
    if (targetAspect >= sourceAspect) {
      cropWidth = width / zoom;
      cropHeight = cropWidth / targetAspect;
      if (cropHeight > height) {
        cropHeight = height.toDouble();
        cropWidth = cropHeight * targetAspect;
      }
    } else {
      cropHeight = height / zoom;
      cropWidth = cropHeight * targetAspect;
      if (cropWidth > width) {
        cropWidth = width.toDouble();
        cropHeight = cropWidth / targetAspect;
      }
    }

    cropWidth = cropWidth.clamp(1.0, width.toDouble());
    cropHeight = cropHeight.clamp(1.0, height.toDouble());

    double left = _cropCenterX.clamp(0.0, 1.0) * width - cropWidth / 2;
    double top = _cropCenterY.clamp(0.0, 1.0) * height - cropHeight / 2;
    left = left.clamp(0.0, width - cropWidth);
    top = top.clamp(0.0, height - cropHeight);

    final bool isFullFrame =
        _cropPreset == _CropPreset.original && zoom <= 1.0001;

    return _CropWindow(
      left: left.round(),
      top: top.round(),
      width: cropWidth.round().clamp(1, width),
      height: cropHeight.round().clamp(1, height),
      isFullFrame: isFullFrame,
    );
  }

  double _desiredCropAspect(double sourceAspect) {
    switch (_cropPreset) {
      case _CropPreset.square:
        return 1;
      case _CropPreset.fourThree:
        return 4 / 3;
      case _CropPreset.threeFour:
        return 3 / 4;
      case _CropPreset.sixteenNine:
        return 16 / 9;
      case _CropPreset.original:
        return sourceAspect;
    }
  }

  String _cropPresetLabel(_CropPreset preset) {
    switch (preset) {
      case _CropPreset.original:
        return 'Original';
      case _CropPreset.square:
        return '1:1';
      case _CropPreset.fourThree:
        return '4:3';
      case _CropPreset.threeFour:
        return '3:4';
      case _CropPreset.sixteenNine:
        return '16:9';
    }
  }

  void _setCropPreset(_CropPreset preset) {
    if (_cropPreset == preset) {
      return;
    }
    setState(() => _cropPreset = preset);
    _schedulePreview();
  }

  void _resetCrop() {
    if (!_hasCustomCrop) {
      return;
    }
    _previewDebounce?.cancel();
    setState(() {
      _cropPreset = _CropPreset.original;
      _cropZoom = 1.0;
      _cropCenterX = 0.5;
      _cropCenterY = 0.5;
    });
    _schedulePreview();
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPadding = MediaQuery.of(context).padding.bottom;
    final bool ready = !_preparing && _error == null && _previewJpeg != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _buildPreviewContent(ready),
              ),
            ),
            if (_error == null)
              _buildAdjustments(ready && !_isSaving, bottomPadding)
            else
              _buildErrorFooter(bottomPadding),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            onPressed:
                _isSaving ? null : () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, color: Colors.white70),
          ),
          const Expanded(
            child: Text(
              'Edit Recent Photo',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildPreviewContent(bool ready) {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }

    if (!ready) {
      return const Center(
        child: CircularProgressIndicator.adaptive(
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
        ),
      );
    }

    final double aspectRatio = _previewAspect <= 0 ? 1 : _previewAspect;

    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.memory(
              _previewJpeg!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAdjustments(bool enabled, double bottomPadding) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xF0101012),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 18,
        bottom: 20 + bottomPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _buildCropControls(enabled),
          const SizedBox(height: 18),
          _buildAdjustmentSlider(
            label: 'Exposure',
            value: _exposureStops,
            min: -1.5,
            max: 1.5,
            divisions: 60,
            displayValue: _exposureStops >= 0
                ? '+${_exposureStops.toStringAsFixed(1)} EV'
                : '${_exposureStops.toStringAsFixed(1)} EV',
            enabled: enabled,
            onChanged: (value) {
              setState(() => _exposureStops = value);
              _schedulePreview();
            },
          ),
          const SizedBox(height: 12),
          _buildAdjustmentSlider(
            label: 'Shadow lift',
            value: _shadowLift,
            min: 0,
            max: 0.6,
            divisions: 30,
            displayValue: '${(_shadowLift * 100).round()}%',
            enabled: enabled,
            onChanged: (value) {
              setState(() => _shadowLift = value);
              _schedulePreview();
            },
          ),
          const SizedBox(height: 12),
          _buildAdjustmentSlider(
            label: 'Saturation',
            value: _saturationDelta,
            min: -0.5,
            max: 0.6,
            divisions: 44,
            displayValue: _formatPercentDelta(_saturationDelta),
            enabled: enabled,
            onChanged: (value) {
              setState(() => _saturationDelta = value);
              _schedulePreview();
            },
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              TextButton(
                onPressed: !_isNeutralAdjustments ? _resetAdjustments : null,
                child: const Text('Reset edits'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _hasCustomCrop ? _resetCrop : null,
                child: const Text('Reset crop'),
              ),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  disabledBackgroundColor: Colors.white24,
                  disabledForegroundColor: Colors.black38,
                ),
                onPressed: (!enabled || _isSaving) ? null : _saveEdits,
                child: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.black87),
                        ),
                      )
                    : const Text('Save copy'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCropControls(bool enabled) {
    final List<_CropPreset> presets = _CropPreset.values;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Crop',
          style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: presets.map((preset) {
            final bool selected = _cropPreset == preset;
            return ChoiceChip(
              label: Text(
                _cropPresetLabel(preset),
                style: const TextStyle(color: Colors.white),
              ),
              selected: selected,
              selectedColor: Colors.white24,
              backgroundColor: Colors.white12,
              onSelected: enabled ? (_) => _setCropPreset(preset) : null,
              showCheckmark: false,
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        _buildAdjustmentSlider(
          label: 'Crop zoom',
          value: _cropZoom,
          min: 1,
          max: 3,
          divisions: 20,
          displayValue: '${_cropZoom.toStringAsFixed(1)}x',
          enabled: enabled,
          onChanged: (value) {
            setState(() => _cropZoom = value);
            _schedulePreview();
          },
        ),
        const SizedBox(height: 12),
        _buildAdjustmentSlider(
          label: 'Horizontal offset',
          value: _cropCenterX,
          min: 0,
          max: 1,
          divisions: 24,
          displayValue: _formatPercentDelta((_cropCenterX - 0.5) * 2),
          enabled: enabled,
          onChanged: (value) {
            setState(() => _cropCenterX = value);
            _schedulePreview();
          },
        ),
        const SizedBox(height: 12),
        _buildAdjustmentSlider(
          label: 'Vertical offset',
          value: _cropCenterY,
          min: 0,
          max: 1,
          divisions: 24,
          displayValue: _formatPercentDelta((_cropCenterY - 0.5) * 2),
          enabled: enabled,
          onChanged: (value) {
            setState(() => _cropCenterY = value);
            _schedulePreview();
          },
        ),
      ],
    );
  }

  Widget _buildAdjustmentSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
    bool enabled = true,
    int? divisions,
  }) {
    final double clamped = value.clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            Text(
              displayValue,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
        Slider(
          value: clamped,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: enabled ? onChanged : null,
          activeColor: Colors.white,
          inactiveColor: Colors.white24,
        ),
      ],
    );
  }

  Widget _buildErrorFooter(double bottomPadding) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        bottom: 24 + bottomPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ?? 'Something went wrong.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatPercentDelta(double value) {
    final int percent = (value * 100).round();
    if (percent == 0) {
      return '0%';
    }
    return percent > 0 ? '+$percent%' : '$percent%';
  }
}
