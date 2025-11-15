import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

Future<String> savePhotoBytesImpl(Uint8List bytes, String extension) async {
  final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final filename = 'NightPlus_$timestamp.$extension';

  if (Platform.isIOS || Platform.isAndroid) {
    final PermissionState permission = await PhotoManager.requestPermissionExtend();
    final bool authorized =
      permission == PermissionState.authorized || permission == PermissionState.limited;
    if (!authorized) {
      throw Exception('Photos permission denied');
    }

    final AssetEntity savedAsset = await PhotoManager.editor.saveImage(
      bytes,
      filename: filename,
    );

    final String? path = savedAsset.relativePath;
    return path ?? filename;
  }

  final directory = await getApplicationDocumentsDirectory();
  final filePath = p.join(directory.path, filename);
  final file = File(filePath);
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
