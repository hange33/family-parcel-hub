/// 取件状态与驿站信息模型 - 纯Dart
library;

enum PickupSource {
  h5,
  notification,
  sms,
  ocr,
  manual,
}

class PickupInfo {
  final String code;
  final String? stationName;
  final String? lockerName;
  final String? phoneTail;
  final PickupSource source;
  final double confidence;
  final DateTime? arrivedAt;

  const PickupInfo({
    required this.code,
    this.stationName,
    this.lockerName,
    this.phoneTail,
    this.source = PickupSource.h5,
    this.confidence = 1.0,
    this.arrivedAt,
  });

  bool get hasCode => code.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'code': code,
    'stationName': stationName,
    'lockerName': lockerName,
    'phoneTail': phoneTail,
    'source': source.name,
    'confidence': confidence,
    'arrivedAt': arrivedAt?.toIso8601String(),
  };

  factory PickupInfo.fromJson(Map<String, dynamic> json) => PickupInfo(
    code: json['code'] as String? ?? '',
    stationName: json['stationName'] as String?,
    lockerName: json['lockerName'] as String?,
    phoneTail: json['phoneTail'] as String?,
    source: PickupSource.values.firstWhere(
      (e) => e.name == json['source'],
      orElse: () => PickupSource.h5,
    ),
    confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    arrivedAt: json['arrivedAt'] != null ? DateTime.tryParse(json['arrivedAt'] as String) : null,
  );
}
