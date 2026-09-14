import 'dart:html' as html;

Future<bool> saveDiagnosticText(String text) async {
  final blob = html.Blob([text], 'text/plain;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    html.AnchorElement(href: url)
      ..download = 'vocaflow-sync-diagnostics.ndjson'
      ..style.display = 'none'
      ..click();
    return true;
  } finally {
    html.Url.revokeObjectUrl(url);
  }
}

Future<bool> shareDiagnosticText(String text, {required String fileName}) =>
    saveDiagnosticText(text);
