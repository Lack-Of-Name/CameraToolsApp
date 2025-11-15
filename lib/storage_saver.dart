import 'dart:typed_data';

import 'storage_saver_stub.dart'
    if (dart.library.io) 'storage_saver_io.dart'
    if (dart.library.html) 'storage_saver_web.dart';

Future<String> saveStackResultBytes(Uint8List bytes, String extension) {
  return saveStackBytesImpl(bytes, extension);
}
