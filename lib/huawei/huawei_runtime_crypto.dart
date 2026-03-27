import 'dart:typed_data';

class HuaweiRuntimeCrypto {
  final Uint8List secretKey;
  final int encryptMethod;
  final int deviceSupportType;
  int encryptionCounter;
  final int sliceSize;

  HuaweiRuntimeCrypto({
    required this.secretKey,
    required this.encryptMethod,
    required this.deviceSupportType,
    required this.encryptionCounter,
    required this.sliceSize,
  });
}
