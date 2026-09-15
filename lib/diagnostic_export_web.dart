import 'dart:html' as html;

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
  final blob = html.Blob([text], 'text/plain;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none'
      ..click();
    return const DiagnosticSaveResult.saved();
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}

Future<bool> shareDiagnosticText(String text, {required String fileName}) =>
    saveDiagnosticText(text, fileName: fileName).then((result) => result.saved);
