import 'package:flutter/foundation.dart';

/// Auxiliary editors share the account's durable learning-state upload queue.
class SyncAuxiliary {
  static Future<void> Function()? onChanged;
  static final revision = ValueNotifier<int>(0);
  static Future<void> commit() async {
    await onChanged?.call();
    revision.value++;
  }
}
