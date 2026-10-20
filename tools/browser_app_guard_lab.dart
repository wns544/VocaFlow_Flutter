// Actual application startup on a localhost-only origin, without initializing
// Firebase. This exercises the production guard and startup error/retry UI.
import 'package:flutter/widgets.dart';
import 'package:vocaflow/main.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(VocaFlowApp(firebaseInitialization: Future.value(false)));
}
