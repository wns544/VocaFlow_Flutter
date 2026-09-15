import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class DiagnosticSaveResult {
  const DiagnosticSaveResult._(this.saved, this.cancelled, this.error);

  const DiagnosticSaveResult.saved() : this._(true, false, null);
  const DiagnosticSaveResult.cancelled() : this._(false, true, null);
  const DiagnosticSaveResult.failed(String error) : this._(false, false, error);

  final bool saved;
  final bool cancelled;
  final String? error;
}

Future<DiagnosticSaveResult> saveDiagnosticText(
  String text, {
  required String fileName,
}) async {
  try {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '상세 동기화 기록 내보내기',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: ['ndjson', 'txt'],
      // Android and iOS save the supplied bytes themselves. A returned path
      // is not necessarily writable by the app, so it must not be written
      // again afterwards.
      bytes: Uint8List.fromList(utf8.encode(text)),
    );
    return path == null
        ? const DiagnosticSaveResult.cancelled()
        : const DiagnosticSaveResult.saved();
  } catch (error) {
    return DiagnosticSaveResult.failed(error.toString());
  }
}

Future<bool> shareDiagnosticText(String text,
    {required String fileName}) async {
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}${Platform.pathSeparator}$fileName');
  await file.writeAsString(text, flush: true);
  final result = await Share.shareXFiles(
    [XFile(file.path, mimeType: 'text/plain')],
    text: 'VocaFlow 진단 보고서입니다. 파일을 첨부합니다.',
  );
  return result.status == ShareResultStatus.success;
}
