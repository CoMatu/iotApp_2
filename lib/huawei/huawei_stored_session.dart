class HuaweiStoredSession {
  final String deviceId;
  final int pairedAtMs;
  final int lastSeenAtMs;
  final int? mtu;
  final int? sliceSize;
  final int? authVersion;
  final int? deviceSupportType;
  final int? authAlgo;
  final int? encryptMethod;
  final String? productModel;
  final int? lastBatteryLevel;
  final String? lastServerNonceHex;
  final int? lastEncryptionCounter;

  const HuaweiStoredSession({
    required this.deviceId,
    required this.pairedAtMs,
    required this.lastSeenAtMs,
    required this.mtu,
    required this.sliceSize,
    required this.authVersion,
    required this.deviceSupportType,
    required this.authAlgo,
    required this.encryptMethod,
    required this.productModel,
    required this.lastBatteryLevel,
    required this.lastServerNonceHex,
    required this.lastEncryptionCounter,
  });

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'pairedAtMs': pairedAtMs,
    'lastSeenAtMs': lastSeenAtMs,
    'mtu': mtu,
    'sliceSize': sliceSize,
    'authVersion': authVersion,
    'deviceSupportType': deviceSupportType,
    'authAlgo': authAlgo,
    'encryptMethod': encryptMethod,
    'productModel': productModel,
    'lastBatteryLevel': lastBatteryLevel,
    'lastServerNonceHex': lastServerNonceHex,
    'lastEncryptionCounter': lastEncryptionCounter,
  };

  static HuaweiStoredSession? fromJson(Map<String, dynamic> json) {
    final deviceId = json['deviceId'];
    final pairedAtMs = json['pairedAtMs'];
    final lastSeenAtMs = json['lastSeenAtMs'];
    if (deviceId is! String || pairedAtMs is! int || lastSeenAtMs is! int) {
      return null;
    }
    return HuaweiStoredSession(
      deviceId: deviceId,
      pairedAtMs: pairedAtMs,
      lastSeenAtMs: lastSeenAtMs,
      mtu: json['mtu'] as int?,
      sliceSize: json['sliceSize'] as int?,
      authVersion: json['authVersion'] as int?,
      deviceSupportType: json['deviceSupportType'] as int?,
      authAlgo: json['authAlgo'] as int?,
      encryptMethod: json['encryptMethod'] as int?,
      productModel: json['productModel'] as String?,
      lastBatteryLevel: json['lastBatteryLevel'] as int?,
      lastServerNonceHex: json['lastServerNonceHex'] as String?,
      lastEncryptionCounter: json['lastEncryptionCounter'] as int?,
    );
  }
}
