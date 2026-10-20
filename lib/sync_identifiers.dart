import 'dart:math';

/// Two independent 16-bit draws retain 32 bits of entropy without requesting
/// 2^32, which Dart's browser secure-random implementation rejects.
String createSyncNonce({Random? random}) {
  final source = random ?? Random.secure();
  return List.generate(
          2, (_) => source.nextInt(1 << 16).toRadixString(36).padLeft(4, '0'))
      .join();
}
