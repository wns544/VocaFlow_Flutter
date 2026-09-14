import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<bool> saveDiagnosticText(String text) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '상세 동기화 기록 내보내기',
    fileName: 'vocaflow-sync-diagnostics.ndjson',
    type: FileType.custom,
    allowedExtensions: ['ndjson', 'txt'],
  );
  if (path == null) return false;
  await File(path).writeAsString(text, flush: true);
  return true;
}

Future<bool> shareDiagnosticText(String text, {required String fileName}) async {
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}${Platform.pathSeparator}$fileName');
  await file.writeAsString(text, flush: true);
  final result = await Share.shareXFiles(
    [XFile(file.path, mimeType: 'text/plain')],
    text: 'VocaFlow 진단 보고서입니다. 파일을 첨부합니다.',
  );
  return result.status == ShareResultStatus.success;
}
