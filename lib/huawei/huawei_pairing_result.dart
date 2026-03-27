import 'huawei_stored_session.dart';

class HuaweiPairingResult {
  final String deviceId;
  final String? productModel;
  final int? batteryLevel;
  final HuaweiStoredSession storedSession;

  const HuaweiPairingResult({
    required this.deviceId,
    required this.productModel,
    required this.batteryLevel,
    required this.storedSession,
  });
}
