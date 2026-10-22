/// 电商订单元数据模型 - 纯Dart
library;

class OrderMeta {
  final String orderId;
  final String platform; // taobao, jd, pdd, douyin, other
  final String title;
  final String? imageUrl;
  final String? trackingNo;
  final String? carrier;
  final String? statusText;
  final double? price;
  final DateTime? orderTime;

  const OrderMeta({
    required this.orderId,
    required this.platform,
    required this.title,
    this.imageUrl,
    this.trackingNo,
    this.carrier,
    this.statusText,
    this.price,
    this.orderTime,
  });

  Map<String, dynamic> toJson() => {
    'orderId': orderId,
    'platform': platform,
    'title': title,
    'imageUrl': imageUrl,
    'trackingNo': trackingNo,
    'carrier': carrier,
    'statusText': statusText,
    'price': price,
    'orderTime': orderTime?.toIso8601String(),
  };

  factory OrderMeta.fromJson(Map<String, dynamic> json) => OrderMeta(
    orderId: json['orderId'] as String? ?? '',
    platform: json['platform'] as String? ?? 'other',
    title: json['title'] as String? ?? '',
    imageUrl: json['imageUrl'] as String?,
    trackingNo: json['trackingNo'] as String?,
    carrier: json['carrier'] as String?,
    statusText: json['statusText'] as String?,
    price: (json['price'] as num?)?.toDouble(),
    orderTime: json['orderTime'] != null ? DateTime.tryParse(json['orderTime'] as String) : null,
  );
}
