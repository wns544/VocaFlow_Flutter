import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'pronunciation_store.dart';

Future<bool> savePronunciationSelections(PronunciationSelectionStore store) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '발음 선택 내보내기',
    fileName: 'vocaflow-pronunciation-selections.json',
    type: FileType.custom,
    allowedExtensions: ['json'],
    bytes: Uint8List.fromList(utf8.encode(store.exportTransferJson())),
  );
  return path != null;
}

Future<int?> importPronunciationSelections(
    PronunciationSelectionStore store) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['json'],
    withData: true,
  );
  final bytes = result?.files.single.bytes;
  if (bytes == null) return null;
  return store.importTransferJson(utf8.decode(bytes));
}
