import 'dart:math';

final Random _random = Random.secure();

/// 128-bit random identifier as 32 hex characters, generated locally so tasks
/// can be created offline and still be globally unique when synced later.
String newId() {
  final buffer = StringBuffer();
  for (var i = 0; i < 4; i++) {
    // 0x100000000 (2^32) is the largest bound Random.nextInt accepts. Do not
    // write it as `1 << 32`: JavaScript shifts wrap at 32 bits, which would
    // make every id on Flutter Web all zeros.
    buffer.write(_random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'));
  }
  return buffer.toString();
}
