class HuaweiLiveMetrics {
  final String? deviceId;
  final bool isConnected;
  final int? heartRate;
  final int? steps;
  final DateTime updatedAt;

  const HuaweiLiveMetrics({
    required this.deviceId,
    required this.isConnected,
    required this.heartRate,
    required this.steps,
    required this.updatedAt,
  });

  factory HuaweiLiveMetrics.disconnected() {
    return HuaweiLiveMetrics(
      deviceId: null,
      isConnected: false,
      heartRate: null,
      steps: null,
      updatedAt: DateTime.now(),
    );
  }

  HuaweiLiveMetrics copyWith({
    String? deviceId,
    bool? isConnected,
    int? heartRate,
    bool clearHeartRate = false,
    int? steps,
    bool clearSteps = false,
  }) {
    return HuaweiLiveMetrics(
      deviceId: deviceId ?? this.deviceId,
      isConnected: isConnected ?? this.isConnected,
      heartRate: clearHeartRate ? null : (heartRate ?? this.heartRate),
      steps: clearSteps ? null : (steps ?? this.steps),
      updatedAt: DateTime.now(),
    );
  }
}
