/// 物流轨迹节点模型 - 纯Dart
library;

class TrackingTrace {
  final String time;
  final String description;
  final String? location;
  final String? statusText;

  const TrackingTrace({
    required this.time,
    required this.description,
    this.location,
    this.statusText,
  });

  Map<String, dynamic> toJson() => {
    'time': time,
    'description': description,
    'location': location,
    'statusText': statusText,
  };

  factory TrackingTrace.fromJson(Map<String, dynamic> json) => TrackingTrace(
    time: json['time'] as String? ?? '',
    description: json['description'] as String? ?? '',
    location: json['location'] as String?,
    statusText: json['statusText'] as String?,
  );
}
