import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import 'preview_screen.dart';

/// A near drop-in clone of the flutter_camera_demo sample with a couple of
/// resilience tweaks so it plays nicely inside this project.
class CameraDemoScreen extends StatefulWidget {
  const CameraDemoScreen({super.key});

  @override
  State<CameraDemoScreen> createState() => _CameraDemoScreenState();
}

class _CameraDemoScreenState extends State<CameraDemoScreen>
    with WidgetsBindingObserver {
  CameraController? controller;
  VideoPlayerController? videoController;

  File? _imageFile;
  File? _videoFile;

  bool _isCameraInitialized = false;
  bool _isCameraPermissionGranted = false;
  bool _isRearCameraSelected = true;
  bool _isVideoCameraSelected = false;
  bool _isRecordingInProgress = false;

  double _minAvailableExposureOffset = 0.0;
  double _maxAvailableExposureOffset = 0.0;
  double _minAvailableZoom = 1.0;
  double _maxAvailableZoom = 1.0;

  double _currentZoomLevel = 1.0;
  double _currentExposureOffset = 0.0;
  FlashMode? _currentFlashMode;

  final List<File> allFileList = [];
  final List<ResolutionPreset> resolutionPresets = ResolutionPreset.values;
  ResolutionPreset currentResolutionPreset = ResolutionPreset.high;

  List<CameraDescription> _cameras = [];
  int _currentCameraIndex = 0;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    getPermissionStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    videoController?.dispose();
    super.dispose();
  }

  Future<void> getPermissionStatus() async {
    await Permission.camera.request();
    final status = await Permission.camera.status;

    if (!mounted) {
      return;
    }

    if (status.isGranted) {
      log('Camera Permission: GRANTED');
      try {
        final cameras = await availableCameras();
        if (!mounted) {
          return;
        }
        setState(() {
          _isCameraPermissionGranted = true;
          _cameras = cameras;
          _currentCameraIndex = _findCameraIndex(CameraLensDirection.back);
          _isRearCameraSelected = _cameras.isEmpty
              ? true
              : _cameras[_currentCameraIndex].lensDirection !=
                  CameraLensDirection.front;
          _cameraError = _cameras.isEmpty ? 'No cameras detected.' : null;
        });
        if (_cameras.isNotEmpty) {
          await onNewCameraSelected(_cameras[_currentCameraIndex]);
          await refreshAlreadyCapturedImages();
        }
      } on CameraException catch (error) {
        setState(() {
          _cameraError = error.description ?? error.code;
        });
      }
    } else {
      log('Camera Permission: DENIED');
      setState(() {
        _isCameraPermissionGranted = false;
      });
    }
  }

  int _findCameraIndex(CameraLensDirection direction) {
    if (_cameras.isEmpty) {
      return 0;
    }
    final index =
        _cameras.indexWhere((camera) => camera.lensDirection == direction);
    if (index == -1) {
      return 0;
    }
    return index;
  }

  Future<void> refreshAlreadyCapturedImages() async {
    final directory = await getApplicationDocumentsDirectory();
    final fileList = await directory.list().toList();
    allFileList.clear();
    final List<Map<int, dynamic>> fileNames = [];

    for (final file in fileList) {
      if (file.path.contains('.jpg') || file.path.contains('.mp4')) {
        allFileList.add(File(file.path));

        final name = file.path.split('/').last.split('.').first;
        fileNames.add({0: int.tryParse(name) ?? 0, 1: file.path.split('/').last});
      }
    }

    if (fileNames.isNotEmpty) {
      final recentFile =
          fileNames.reduce((curr, next) => curr[0] > next[0] ? curr : next);
      final recentFileName = recentFile[1] as String;
      if (recentFileName.contains('.mp4')) {
        _videoFile = File('${directory.path}/$recentFileName');
        _imageFile = null;
        await _startVideoPlayer();
      } else {
        _imageFile = File('${directory.path}/$recentFileName');
        _videoFile = null;
      }

      setState(() {});
    }
  }

  Future<XFile?> takePicture() async {
    final cameraController = controller;

    if (cameraController == null || cameraController.value.isTakingPicture) {
      return null;
    }

    try {
      return await cameraController.takePicture();
    } on CameraException catch (e) {
      debugPrint('Error occured while taking picture: $e');
      return null;
    }
  }

  Future<void> _startVideoPlayer() async {
    if (_videoFile != null) {
      videoController = VideoPlayerController.file(_videoFile!);
      await videoController!.initialize();
      await videoController!.setLooping(true);
      await videoController!.play();
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> startVideoRecording() async {
    final cameraController = controller;

    if (cameraController == null || cameraController.value.isRecordingVideo) {
      return;
    }

    try {
      await cameraController.startVideoRecording();
      setState(() {
        _isRecordingInProgress = true;
      });
    } on CameraException catch (e) {
      debugPrint('Error starting to record video: $e');
    }
  }

  Future<XFile?> stopVideoRecording() async {
    final cameraController = controller;
    if (cameraController == null || !cameraController.value.isRecordingVideo) {
      return null;
    }

    try {
      final file = await cameraController.stopVideoRecording();
      setState(() {
        _isRecordingInProgress = false;
      });
      return file;
    } on CameraException catch (e) {
      debugPrint('Error stopping video recording: $e');
      return null;
    }
  }

  Future<void> pauseVideoRecording() async {
    final cameraController = controller;
    if (cameraController == null || !cameraController.value.isRecordingVideo) {
      return;
    }

    try {
      await cameraController.pauseVideoRecording();
    } on CameraException catch (e) {
      debugPrint('Error pausing video recording: $e');
    }
  }

  Future<void> resumeVideoRecording() async {
    final cameraController = controller;
    if (cameraController == null || !cameraController.value.isRecordingVideo) {
      return;
    }

    try {
      await cameraController.resumeVideoRecording();
    } on CameraException catch (e) {
      debugPrint('Error resuming video recording: $e');
    }
  }

  void resetCameraValues() {
    _currentZoomLevel = 1.0;
    _currentExposureOffset = 0.0;
  }

  Future<void> onNewCameraSelected(CameraDescription cameraDescription) async {
    final previousCameraController = controller;

    final cameraController = CameraController(
      cameraDescription,
      currentResolutionPreset,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await previousCameraController?.dispose();

    resetCameraValues();

    if (mounted) {
      setState(() {
        controller = cameraController;
      });
    }

    cameraController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });

    try {
      await cameraController.initialize();
      await Future.wait([
        cameraController
            .getMinExposureOffset()
            .then((value) => _minAvailableExposureOffset = value),
        cameraController
            .getMaxExposureOffset()
            .then((value) => _maxAvailableExposureOffset = value),
        cameraController
            .getMaxZoomLevel()
            .then((value) => _maxAvailableZoom = value),
        cameraController
            .getMinZoomLevel()
            .then((value) => _minAvailableZoom = value),
      ]);

      _currentFlashMode = controller!.value.flashMode;
    } on CameraException catch (e) {
      debugPrint('Error initializing camera: $e');
    }

    if (mounted) {
      setState(() {
        _isCameraInitialized = controller!.value.isInitialized;
      });
    }
  }

  void onViewFinderTap(TapDownDetails details, BoxConstraints constraints) {
    if (controller == null) {
      return;
    }

    final offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    controller!.setExposurePoint(offset);
    controller!.setFocusPoint(offset);
  }

  Future<void> _handleCameraSwap() async {
    if (_cameras.length < 2) {
      return;
    }
    final bool targetRear = !_isRearCameraSelected;
    final nextIndex = _findCameraIndex(
      targetRear ? CameraLensDirection.back : CameraLensDirection.front,
    );
    if (nextIndex == _currentCameraIndex) {
      return;
    }
    setState(() {
      _isCameraInitialized = false;
      _currentCameraIndex = nextIndex;
      _isRearCameraSelected =
          _cameras[nextIndex].lensDirection != CameraLensDirection.front;
    });
    await onNewCameraSelected(_cameras[nextIndex]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cameraController = controller;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (_cameras.isNotEmpty) {
        onNewCameraSelected(_cameras[_currentCameraIndex]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _isCameraPermissionGranted
            ? _isCameraInitialized
                ? Column(
                    children: [
                      AspectRatio(
                        aspectRatio: controller!.value.aspectRatio == 0
                            ? 1
                            : 1 / controller!.value.aspectRatio,
                        child: Stack(
                          children: [
                            CameraPreview(
                              controller!,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (details) =>
                                        onViewFinderTap(details, constraints),
                                  );
                                },
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              bottom: 0,
                              child: _buildRightRail(),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _buildCaptureControls(),
                            ),
                          ],
                        ),
                      ),
                      _buildControlsSection(),
                    ],
                  )
                : Center(
                    child: Text(
                      _cameraError ?? 'LOADING',
                      style: const TextStyle(color: Colors.white),
                    ),
                  )
            : _buildPermissionPrompt(),
      ),
    );
  }

  Widget _buildRightRail() {
    final bool exposureAdjustable =
        _maxAvailableExposureOffset > _minAvailableExposureOffset + 0.0001;
    return SafeArea(
      minimum: const EdgeInsets.only(top: 16, right: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildResolutionDropdown(),
          if (exposureAdjustable) ...[
            const SizedBox(height: 12),
            _buildExposureReadout(),
          ],
        ],
      ),
    );
  }

  Widget _buildResolutionDropdown() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(10.0),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: DropdownButton<ResolutionPreset>(
          dropdownColor: Colors.black87,
          underline: Container(),
          value: currentResolutionPreset,
          items: [
            for (final preset in resolutionPresets)
              DropdownMenuItem(
                value: preset,
                child: Text(
                  preset.toString().split('.')[1].toUpperCase(),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
          ],
          onChanged: (value) {
            if (value == null || _cameras.isEmpty) {
              return;
            }
            setState(() {
              currentResolutionPreset = value;
              _isCameraInitialized = false;
            });
            onNewCameraSelected(_cameras[_currentCameraIndex]);
          },
        ),
      ),
    );
  }

  Widget _buildExposureReadout() {
    final String evLabel = _currentExposureOffset >= 0
        ? '+${_currentExposureOffset.toStringAsFixed(1)} EV'
        : '${_currentExposureOffset.toStringAsFixed(1)} EV';
    final int isoEstimate = _estimateIsoFromExposure(_currentExposureOffset);
    return Container(
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(10.0),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'ISO $isoEstimate',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            evLabel,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  int _estimateIsoFromExposure(double exposureOffset) {
    final double iso = 100 * (math.pow(2.0, exposureOffset) as double);
    final double clamped = iso.clamp(25.0, 12800.0);
    return clamped.round();
  }

  String _formatExposureSliderLabel() {
    final String evLabel = _currentExposureOffset >= 0
        ? '+${_currentExposureOffset.toStringAsFixed(1)} EV'
        : '${_currentExposureOffset.toStringAsFixed(1)} EV';
    final int isoEstimate = _estimateIsoFromExposure(_currentExposureOffset);
    return '$evLabel • ISO $isoEstimate';
  }

  Widget _buildLabeledSlider({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required Future<void> Function(double) onChanged,
    bool enabled = true,
  }) {
    final double sliderMin = math.min(min, max);
    final double sliderMax = math.max(min, max);
    final double sliderRange = sliderMax - sliderMin;
    final bool adjustable = enabled && sliderRange > 0.0001;
    final double effectiveMax = adjustable ? sliderMax : sliderMin + 1.0;
    final double clampedValue = value.isFinite
        ? value.clamp(sliderMin, sliderMax)
        : sliderMin;

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
              valueLabel,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
        Slider(
          value: adjustable ? clampedValue : sliderMin,
          min: sliderMin,
          max: effectiveMax,
          onChanged: adjustable
              ? (double newValue) {
                  onChanged(newValue);
                }
              : null,
          activeColor: Colors.white,
          inactiveColor: Colors.white24,
        ),
      ],
    );
  }

  Widget _buildCaptureControls() {
    return SafeArea(
      minimum: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: _isRecordingInProgress
                ? () async {
                    if (controller!.value.isRecordingPaused) {
                      await resumeVideoRecording();
                    } else {
                      await pauseVideoRecording();
                    }
                  }
                : _handleCameraSwap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(
                  Icons.circle,
                  color: Colors.black38,
                  size: 60,
                ),
                _isRecordingInProgress
                    ? controller!.value.isRecordingPaused
                        ? const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 30,
                          )
                        : const Icon(
                            Icons.pause,
                            color: Colors.white,
                            size: 30,
                          )
                    : Icon(
                        _isRearCameraSelected
                            ? Icons.camera_front
                            : Icons.camera_rear,
                        color: Colors.white,
                        size: 30,
                      ),
              ],
            ),
          ),
          InkWell(
            onTap: _isVideoCameraSelected
                ? () async {
                    if (_isRecordingInProgress) {
                      final rawVideo = await stopVideoRecording();
                      if (rawVideo == null) {
                        return;
                      }
                      final videoFile = File(rawVideo.path);
                      final currentUnix =
                          DateTime.now().millisecondsSinceEpoch;
                      final directory =
                          await getApplicationDocumentsDirectory();
                      final fileFormat = videoFile.path.split('.').last;
                      _videoFile = await videoFile.copy(
                        '${directory.path}/$currentUnix.$fileFormat',
                      );
                      await _startVideoPlayer();
                    } else {
                      await startVideoRecording();
                    }
                  }
                : () async {
                    final rawImage = await takePicture();
                    if (rawImage == null) {
                      return;
                    }
                    final imageFile = File(rawImage.path);
                    final currentUnix =
                        DateTime.now().millisecondsSinceEpoch;
                    final directory =
                        await getApplicationDocumentsDirectory();
                    final fileFormat = imageFile.path.split('.').last;
                    await imageFile.copy(
                      '${directory.path}/$currentUnix.$fileFormat',
                    );
                    await refreshAlreadyCapturedImages();
                  },
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.circle,
                  color:
                      _isVideoCameraSelected ? Colors.white : Colors.white38,
                  size: 80,
                ),
                Icon(
                  Icons.circle,
                  color: _isVideoCameraSelected ? Colors.red : Colors.white,
                  size: 65,
                ),
                if (_isVideoCameraSelected && _isRecordingInProgress)
                  const Icon(
                    Icons.stop_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
              ],
            ),
          ),
          InkWell(
            onTap: _imageFile != null
                ? () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => PreviewScreen(
                          imageFile: _imageFile!,
                          fileList: allFileList,
                        ),
                      ),
                    );
                  }
                : null,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10.0),
                border: Border.all(
                  color: Colors.white,
                  width: 2,
                ),
                image: _imageFile != null
                    ? DecorationImage(
                        image: FileImage(_imageFile!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: videoController != null &&
                      videoController!.value.isInitialized
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8.0),
                      child: AspectRatio(
                        aspectRatio: videoController!.value.aspectRatio,
                        child: VideoPlayer(videoController!),
                      ),
                    )
                  : Container(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsSection() {
    return Expanded(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8.0, right: 4.0),
                      child: TextButton(
                        onPressed: _isRecordingInProgress
                            ? null
                            : () {
                                if (_isVideoCameraSelected) {
                                  setState(() {
                                    _isVideoCameraSelected = false;
                                  });
                                }
                              },
                        style: TextButton.styleFrom(
                          foregroundColor: _isVideoCameraSelected
                              ? Colors.black54
                              : Colors.black,
                          backgroundColor: _isVideoCameraSelected
                              ? Colors.white30
                              : Colors.white,
                        ),
                        child: const Text('IMAGE'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4.0, right: 8.0),
                      child: TextButton(
                        onPressed: () {
                          if (!_isVideoCameraSelected) {
                            setState(() {
                              _isVideoCameraSelected = true;
                            });
                          }
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: _isVideoCameraSelected
                              ? Colors.black
                              : Colors.black54,
                          backgroundColor: _isVideoCameraSelected
                              ? Colors.white
                              : Colors.white30,
                        ),
                        child: const Text('VIDEO'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  InkWell(
                    onTap: () async {
                      setState(() {
                        _currentFlashMode = FlashMode.off;
                      });
                      await controller?.setFlashMode(FlashMode.off);
                    },
                    child: Icon(
                      Icons.flash_off,
                      color: _currentFlashMode == FlashMode.off
                          ? Colors.amber
                          : Colors.white,
                    ),
                  ),
                  InkWell(
                    onTap: () async {
                      setState(() {
                        _currentFlashMode = FlashMode.auto;
                      });
                      await controller?.setFlashMode(FlashMode.auto);
                    },
                    child: Icon(
                      Icons.flash_auto,
                      color: _currentFlashMode == FlashMode.auto
                          ? Colors.amber
                          : Colors.white,
                    ),
                  ),
                  InkWell(
                    onTap: () async {
                      setState(() {
                        _currentFlashMode = FlashMode.always;
                      });
                      await controller?.setFlashMode(FlashMode.always);
                    },
                    child: Icon(
                      Icons.flash_on,
                      color: _currentFlashMode == FlashMode.always
                          ? Colors.amber
                          : Colors.white,
                    ),
                  ),
                  InkWell(
                    onTap: () async {
                      setState(() {
                        _currentFlashMode = FlashMode.torch;
                      });
                      await controller?.setFlashMode(FlashMode.torch);
                    },
                    child: Icon(
                      Icons.highlight,
                      color: _currentFlashMode == FlashMode.torch
                          ? Colors.amber
                          : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 16.0),
              child: Column(
                children: [
                  _buildLabeledSlider(
                    label: 'Exposure Bias',
                    valueLabel: _formatExposureSliderLabel(),
                    value: _currentExposureOffset,
                    min: _minAvailableExposureOffset,
                    max: _maxAvailableExposureOffset,
                    enabled: _maxAvailableExposureOffset >
                        _minAvailableExposureOffset + 0.0001,
                    onChanged: (value) async {
                      setState(() {
                        _currentExposureOffset = value;
                      });
                      await controller?.setExposureOffset(value);
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildLabeledSlider(
                    label: 'Zoom',
                    valueLabel: '${_currentZoomLevel.toStringAsFixed(1)}x',
                    value: _currentZoomLevel,
                    min: _minAvailableZoom,
                    max: _maxAvailableZoom,
                    enabled: _maxAvailableZoom > _minAvailableZoom + 0.0001,
                    onChanged: (value) async {
                      setState(() {
                        _currentZoomLevel = value;
                      });
                      await controller?.setZoomLevel(value);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionPrompt() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Permission denied',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: getPermissionStatus,
          child: const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text(
              'Give permission',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
