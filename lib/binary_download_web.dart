import 'dart:html' as html;
import 'dart:typed_data';

/// Browsers do not expose a writable file path. Triggering a Blob download is
/// the reliable equivalent of a native save dialog and reports success once
/// the browser has accepted the user-initiated download.
Future<bool> saveBinaryDownload(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) async {
  final blob = html.Blob([bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none'
      ..click();
    return true;
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}
