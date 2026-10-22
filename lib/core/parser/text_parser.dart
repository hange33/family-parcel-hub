/// 文本解析器 - 核心层
/// 
/// 职责：
/// 1. 协调各个提取器
/// 2. 提供单条和批量解析
/// 3. 处理多包裹文本
/// 4. 计算置信度和警告
library;

import '../models/package.dart';
import '../models/package_status.dart';
import 'text_preprocessor.dart';
import 'extractors.dart';
import 'parse_result.dart';
import 'regex_patterns.dart';

/// 文本解析器
class TextParser {
  /// 单号前缀 → 快递公司映射
  /// 使用位数范围而非精确值，以容忍OCR漏识别或多识别数字
  static final Map<RegExp, CourierType> _trackingPrefixMap = {
    RegExp(r'JT\d{10,20}'): CourierType.jt,   // 极兔
    RegExp(r'SF\d{10,20}'): CourierType.sf,   // 顺丰
    RegExp(r'YT\d{10,20}'): CourierType.yt,   // 圆通
    RegExp(r'ZT\d{10,20}'): CourierType.zto,  // 中通
    RegExp(r'YD\d{10,20}'): CourierType.yd,   // 韵达
    RegExp(r'ST\d{10,20}'): CourierType.sto,  // 申通
    RegExp(r'JD\d{10,20}'): CourierType.jd,   // 京东
  };

  /// 通过单号前缀反推快递公司
  static ExtractionResult<CourierType> _extractCourierFromTracking(String text) {
    for (final entry in _trackingPrefixMap.entries) {
      final match = entry.key.firstMatch(text);
      if (match != null) {
        return ExtractionResult(
          value: entry.value,
          confidence: 0.95,
          source: 'tracking_prefix',
        );
      }
    }
    return ExtractionResult(
      value: CourierType.other,
      confidence: 0.0,
      source: 'no_match',
    );
  }

  /// 解析单条文本
  static ParseResult parse(String text) {
    final raw = TextPreprocessor.preprocess(text);
    
    // 先用单号前缀反推快递公司（优先级更高）
    final trackingCourier = _extractCourierFromTracking(raw);
    final keywordCourier = CourierExtractor.extract(raw);
    
    // 如果单号前缀匹配成功，优先使用
    var courier = trackingCourier.confidence > 0 
        ? trackingCourier 
        : keywordCourier;
    
    final pickupCode = PickupCodeExtractor.extract(raw);
    var trackingNumber = TrackingNumberExtractor.extract(raw);
    final phoneTail = PhoneTailExtractor.extract(raw);

    // 兜底1：courier 为 "other" 但运单号有已知前缀 → 从运单号反推快递商
    // 例如：PDD截图OCR未识别"圆通"但识别出"YT8866295706389"
    if (courier.value == CourierType.other &&
        trackingNumber.value.isNotEmpty) {
      final inferredCourier = _extractCourierFromTracking(trackingNumber.value);
      if (inferredCourier.confidence > 0) {
        courier = ExtractionResult<CourierType>(
          value: inferredCourier.value,
          confidence: 0.88,
          source: 'tracking_number_fallback',
        );
      }
    }

    // 兜底2：courier 已识别但单号为空 → 用宽松长数字匹配
    // OCR 场景：单号常被识别为无标签的长数字串
    if (trackingNumber.value.isEmpty && courier.confidence > 0) {
      final looseMatch = RegexPatterns.looseNumericTracking.firstMatch(raw);
      if (looseMatch != null) {
        final number = looseMatch.group(1)!;
        if (!RegexPatterns.phoneNumber.hasMatch(number)) {
          trackingNumber = ExtractionResult(
            value: number,
            confidence: 0.6,
            source: 'courier_guarded_loose',
          );
        }
      }
    }
    final locationResult = LocationExtractor.extractTyped(raw);
    final stationName = StationExtractor.extract(raw);
    final station = ExtractionResult(
      value: stationName,
      confidence: stationName.isNotEmpty ? 0.9 : 0.0,
      source: stationName.isNotEmpty ? 'station_keyword' : null,
    );
    final cleanedLocation = StationExtractor.cleanLocation(locationResult.value, stationName);
    final location = ExtractionResult(
      value: cleanedLocation,
      confidence: locationResult.confidence,
      source: locationResult.source,
    );
    var status = StatusExtractor.extract(raw);

    // 取件码存在 → 状态不可能是"已取件"
    // 有取件码 = 包裹在驿站等你取，不是已取走
    if (pickupCode.value.isNotEmpty &&
        status.value == PackageStatus.pickedUp) {
      status = ExtractionResult(
        value: PackageStatus.arrived,
        confidence: 0.95,
        source: 'pickup_code_override',
      );
    }

    final warnings = <String>[];
    
    // 计算总体置信度
    final confidences = [
      courier.confidence,
      pickupCode.confidence,
      trackingNumber.confidence,
      phoneTail.confidence,
      location.confidence,
      status.confidence,
    ];
    
    final validConfidences = confidences.where((c) => c > 0).toList();
    final overallConfidence = validConfidences.isEmpty 
        ? 0.0 
        : validConfidences.reduce((a, b) => a + b) / validConfidences.length;
    
    return ParseResult(
      courier: courier,
      pickupCode: pickupCode,
      trackingNumber: trackingNumber,
      phoneTail: phoneTail,
      location: location,
      locationType: locationResult.type,
      station: station,
      status: status,
      warnings: warnings,
      overallConfidence: overallConfidence,
    );
  }

  /// 解析多条文本（批量）
  static List<ParseResult> parseMulti(String text) {
    final raw = TextPreprocessor.preprocess(text);
    final boundaries = _findBoundaries(raw);

    if (boundaries.length <= 1) {
      return [parse(text)];
    }

    final commonHeader = boundaries[0] > 10 
        ? raw.substring(0, boundaries[0]) 
        : '';

    final results = <ParseResult>[];
    for (var i = 0; i < boundaries.length; i++) {
      final start = boundaries[i];
      final end = i + 1 < boundaries.length 
          ? boundaries[i + 1] 
          : raw.length;
      var segment = raw.substring(start, end);
      if (commonHeader.isNotEmpty) {
        segment = '$commonHeader\n$segment';
      }
      results.add(parse(segment));
    }
    return results;
  }

  /// 查找文本中的包裹边界
  static List<int> _findBoundaries(String text) {
    final positions = <_BoundaryInfo>[];

    // 取件码/取货码（带标签）
    for (final m in RegexPatterns.labeledPickupCode.allMatches(text)) {
      final code = m.group(1) ?? '';
      positions.add(_BoundaryInfo(m.start, code, 'labeled'));
    }

    // 裸bay码 (N-N-NNNN)
    for (final m in RegexPatterns.bayFormatCode.allMatches(text)) {
      final code = m.group(0) ?? '';
      final isDuplicate = positions.any((p) =>
        p.code == code && (p.position - m.start).abs() < 50);
      if (!isDuplicate) {
        positions.add(_BoundaryInfo(m.start, code, 'bay'));
      }
    }

    // "取件出单号后五位" 格式（如：06389）
    final tailCodePattern = RegExp(r'(?:取件出单号|单号)[后之]?[尾末五]位[：:\s]*(\d{4,6})');
    for (final m in tailCodePattern.allMatches(text)) {
      final code = m.group(1) ?? '';
      final isDuplicate = positions.any((p) =>
        p.code == code && (p.position - m.start).abs() < 50);
      if (!isDuplicate) {
        positions.add(_BoundaryInfo(m.start, code, 'tail_code'));
      }
    }

    positions.sort((a, b) => a.position.compareTo(b.position));
    return positions.map((p) => p.position).toList();
  }

  /// 向后兼容的解析方法
  static ParsedPackage parseLegacy(String text) {
    return parse(text).toParsedPackage();
  }

  /// 向后兼容的批量解析方法
  static List<ParsedPackage> parseMultiLegacy(String text) {
    return parseMulti(text).map((r) => r.toParsedPackage()).toList();
  }
}

/// 边界信息（用于去重）
class _BoundaryInfo {
  final int position;
  final String code;
  final String type;
  
  _BoundaryInfo(this.position, this.code, this.type);
}
