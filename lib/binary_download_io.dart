import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Uses the platform save dialog on native/desktop builds.
Future<bool> saveBinaryDownload(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) async =>
    await FilePicker.platform.saveFile(
      dialogTitle: '파일 저장',
      fileName: fileName,
      bytes: bytes,
    ) !=
    null;
