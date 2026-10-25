// Run with: flutter test --platform chrome test/web_archive_browser_test.dart
import 'web_archive_browser_stub.dart'
    if (dart.library.html) 'web_archive_browser_cases.dart' as platform;

void main() {
  platform.registerWebArchiveTests();
}
