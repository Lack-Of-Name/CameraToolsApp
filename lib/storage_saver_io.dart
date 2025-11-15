import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> saveStackBytesImpl(Uint8List bytes, String extension) async {
  final directory = await getApplicationDocumentsDirectory();
  final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final filePath = p.join(directory.path, 'stack_$timestamp.$extension');
  final file = File(filePath);
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
