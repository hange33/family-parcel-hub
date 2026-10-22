/// 提取器接口和实现 - 纯逻辑
/// 
/// 职责：
/// 1. 定义提取器接口
/// 2. 实现各种字段提取器
/// 3. 使用词典和regex
library;

import '../models/package.dart';
import '../models/package_status.dart';
import 'courier_dictionary.dart';
import 'location_type.dart';
import 'status_dictionary.dart';
import 'regex_patterns.dart';
import 'text_preprocessor.dart';

/// 提取结果
class ExtractionResult<T> {
  final T value;
  final double confidence;
  final String? source;
  
  const ExtractionResult({
    required this.value,
    this.confidence = 1.0,
    this.source,
  });
}

/// 快递公司提取器
class CourierExtractor {
  static ExtractionResult<CourierType> extract(String text) {
    final lower = text.toLowerCase();
    String? found;
    var maxLen = 0;
    bool isSpecific = false;

    // 优先级0：先检查运单号前缀！（SF, YT, ZTO, JD, JT 等！）
    // 先从运单号前缀匹配！
    final trackingMatch = _extractByTrackingPrefix(text);
    if (trackingMatch != null) {
      return trackingMatch;
    }

    // 按 key 长度降序，确保长别名优先匹配
    final sorted = CourierDictionary.platformAliases.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in sorted) {
      if (!lower.contains(entry.key.toLowerCase())) continue;

      final isSpecificMatch = CourierDictionary.specificCouriers
          .any((s) => entry.key.contains(s) || s.contains(entry.key));

      if (isSpecificMatch || entry.key.length > maxLen) {
        maxLen = isSpecificMatch ? 999 : entry.key.length;
        found = entry.value;
        isSpecific = isSpecificMatch;
      }
    }

    if (found == null) {
      return ExtractionResult(
        value: CourierType.other,
        confidence: 0.0,
        source: 'no_match',
      );
    }

    final courierType = CourierDictionary.getCourierType(found);
    return ExtractionResult(
      value: courierType,
      confidence: isSpecific ? 0.95 : 0.8,
      source: 'keyword_match',
    );
  }

  /// 通过运单号前缀提取快递商
  static ExtractionResult<CourierType>? _extractByTrackingPrefix(String text) {
    // 检查运单号前缀（SF, YT, ZTO, JT, JD 等
    if (RegexPatterns.sfTracking.hasMatch(text)) {
      return ExtractionResult(
        value: CourierType.sf,
        confidence: 0.92,
        source: 'tracking_prefix_sf',
      );
    }
    if (RegexPatterns.ytTracking.hasMatch(text) || RegexPatterns.yt88Tracking.hasMatch(text)) {
      return ExtractionResult(
        value: CourierType.yt,
        confidence: 0.92,
        source: 'tracking_prefix_yt',
      );
    }
    if (RegexPatterns.ztoTracking.hasMatch(text)) {
      return ExtractionResult(
        value: CourierType.zto,
        confidence: 0.92,
        source: 'tracking_prefix_zto',
      );
    }
    if (RegexPatterns.jtTracking.hasMatch(text)) {
      return ExtractionResult(
        value: CourierType.jt,
        confidence: 0.92,
        source: 'tracking_prefix_jt',
      );
    }
    if (RegexPatterns.jdTracking.hasMatch(text)) {
      return ExtractionResult(
        value: CourierType.jd,
        confidence: 0.92,
        source: 'tracking_prefix_jd',
      );
    }
    return null;
  }
}

/// 取件码提取器
class PickupCodeExtractor {
  /// 验证取件码是否有效
  /// 禁止：纯字母开头、单独4位数字（可能是日期）
  static bool _isValidPickupCode(String code) {
    if (code.isEmpty) return false;
    // 禁止纯字母开头（2个或更多字母）
    if (RegExp(r'^[a-zA-Z]{2,}').hasMatch(code)) return false;
    return true;
  }

  /// 规范化取件码：合并连续横杠、去除首尾横杠、修正 OCR 误识别
  static String _normalizePickupCode(String code) {
    var normalized = code;
    // 中文横杠转普通横杠
    normalized = normalized.replaceAll('—', '-');
    normalized = normalized.replaceAll('－', '-');
    
    // 修正 OCR 字母转数字误识别：O → 0，o → 0，I → 1，l → 1
    normalized = normalized.replaceAll('O', '0');
    normalized = normalized.replaceAll('o', '0');
    normalized = normalized.replaceAll('I', '1');
    normalized = normalized.replaceAll('l', '1');
    
    // 合并连续横杠：-- → -，--- → -，等等
    normalized = normalized.replaceAll(RegExp(r'[-—－]{2,}'), '-');
    // 去除首尾横杠
    normalized = normalized.replaceAll(RegExp(r'^[-—－]+|[-—－]+$'), '');
    return normalized;
  }
  
  /// 检查是否为“可疑的日期格式”
  /// 如：0407, 0509, 1234
  static bool _isSuspiciousDateCode(String code) {
    // 纯4位数字，可能是日期（MMDD格式）
    if (RegExp(r'^\d{4}$').hasMatch(code)) {
      // 检查是否可能是日期（01-12月，01-31日）
      final month = int.tryParse(code.substring(0, 2));
      final day = int.tryParse(code.substring(2, 4));
      if (month != null && day != null) {
        if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
          return true; // 可能是日期
        }
      }
    }
    return false;
  }

  static ExtractionResult<String> extract(String text) {
    // Priority 1: 带标签的取件码
    final labelMatch = RegexPatterns.labeledPickupCode.firstMatch(text);
    if (labelMatch != null) {
      final code = _normalizePickupCode(labelMatch.group(1)!);
      if (_isValidPickupCode(code) && !RegExp(r'^\d{10,}$').hasMatch(code)) {
        return ExtractionResult(
          value: code,
          confidence: 0.95,
          source: 'labeled_code',
        );
      }
    }

    // Priority 2: 短格式取件码
    final shortMatch = RegexPatterns.shortPickupCode.firstMatch(text);
    if (shortMatch != null) {
      final code = _normalizePickupCode(shortMatch.group(1)!);
      if (_isValidPickupCode(code) && !RegExp(r'^\d{10,}$').hasMatch(code)) {
        return ExtractionResult(
          value: code,
          confidence: 0.9,
          source: 'short_code',
        );
      }
    }

    // Priority 3: Bay格式
    final bayMatch = RegexPatterns.bayFormatCode.firstMatch(text);
    if (bayMatch != null) {
      final code = _normalizePickupCode(bayMatch.group(0)!);
      if (_isValidPickupCode(code)) {
        return ExtractionResult(
          value: code,
          confidence: 0.85,
          source: 'bay_format',
        );
      }
    }

    // Priority 3.5: PDD"取件出单号后五位"格式（如：06389）
    final tailCodePattern = RegExp(r'(?:取件出单号|单号)[后之]?[尾末五]位[：:\s]*(\d{4,6})');
    final tailMatch = tailCodePattern.firstMatch(text);
    if (tailMatch != null) {
      final code = tailMatch.group(1)!;
      if (_isValidPickupCode(code)) {
        return ExtractionResult(
          value: code,
          confidence: 0.88,
          source: 'tail_code',
        );
      }
    }

    // Priority 4: 4-8位数字
    // 收紧规则：
    // 1. 禁止单独4位数字（可能是日期如0407）
    // 2. 必须检查数字附近 10~20 字符内是否有取件码关键词
    for (final m in RegexPatterns.digitCode.allMatches(text)) {
      final code = m.group(1)!;
      final before = text.substring(0, m.start);
      final after = text.substring(m.end);
      
      // 检查数字附近 20 字符内是否有取件码关键词
      final contextBefore = before.length > 20 
          ? before.substring(before.length - 20) 
          : before;
      final contextAfter = after.length > 20 
          ? after.substring(0, 20) 
          : after;
      final context = '$contextBefore$code$contextAfter';
      
      final hasLabelContext = RegExp(r'(?:取件码|取货码|提取码|验证码|收件码|凭码)')
          .hasMatch(context);
      
      // 如果没有关键词上下文，且是可疑日期格式，则拒绝
      if (!hasLabelContext && _isSuspiciousDateCode(code)) {
        continue; // 跳过这个匹配
      }
      
      // 检查是否为客服电话、订单号等非取件码数字
      final isNonPickupNumber = RegExp(r'(?:联系|客服|电话|热线|电话|订单|运单|物流问题)')
          .hasMatch(context);
      
      if (isNonPickupNumber) {
        continue; // 跳过客服电话等
      }
      
      if (_isValidPickupCode(code) &&
          !RegexPatterns.trackingPrefix.hasMatch(before) &&
          !RegexPatterns.courierPrefix.hasMatch(code)) {
        // 没有上下文关键词时，大幅降低置信度
        final confidence = hasLabelContext ? 0.8 : 0.3;
        return ExtractionResult(
          value: _normalizePickupCode(code),
          confidence: confidence,
          source: hasLabelContext ? 'digit_code_with_context' : 'digit_code_no_context',
        );
      }
    }

    return ExtractionResult(
      value: '',
      confidence: 0.0,
      source: 'no_match',
    );
  }
}

/// 取货地点提取器
class LocationExtractor {
  /// 物流节点关键词（不是取件地点）- 需要过滤掉
  static const List<String> _logisticsNodeKeywords = [
    '转运中心', '分拨中心', '集运仓', '物流园', '运输中心',
    '分拣中心', '中转站', '配送中心',
    '集散中心', '处理中心', '航空港',
    '集货点', '漯河集货点', '廊坊临空转运中心',
    '深圳转运中心', '南昌转运', '邮城网点',
  ];

  /// 取件站点关键词
  static const List<String> _pickupStationKeywords = [
    '菜鸟驿站', '菜鸟', '代收点', '丰巢', '快递柜',
    '妈妈驿站', '驿站', '营业部', '网点', '自提点',
    '服务点', '门店', '北门店', '南门店', '东门店', '西门店',
    '大院驿站',
  ];

  /// 检查是否为物流节点（不是取件地点）
  static bool _isLogisticsNode(String location) {
    return _logisticsNodeKeywords.any((kw) => location.contains(kw));
  }

  /// 检查是否为取件站点
  static bool _isPickupStation(String location) {
    return _pickupStationKeywords.any((kw) => location.contains(kw));
  }

  /// 确定位置类型
  static LocationType _determineLocationType(String location) {
    if (_isLogisticsNode(location)) {
      return LocationType.transitCenter;
    }
    if (_isPickupStation(location)) {
      return LocationType.pickupStation;
    }
    return LocationType.unknown;
  }

  static LocationParseResult extractTyped(String text) {
    // Priority 0: 收货地址格式 (最高优先级)
    final shippingAddrMatch = RegExp(
      r'(?:收货地址|发货地址|地址)[：:\s]*([\u4e00-\u9fa5]{2,50})',
    ).firstMatch(text);
    if (shippingAddrMatch != null) {
      var loc = shippingAddrMatch.group(1) ?? '';
      loc = loc.replaceAll(RegExp(r'[展开查看更多>]+$'), '').trim();
      if (loc.length >= 4 && !_isLogisticsNode(loc)) {
        return LocationParseResult(
          value: loc,
          type: LocationType.pickupStation,
          confidence: 0.92,
          source: 'shipping_address',
        );
      }
    }

    // Priority 0.5: "收 xxx" 格式（极兔等快递使用）
    // 匹配独立行的 "收 地址内容"
    final receiveMatch = RegExp(r'\n\s*收\s+([\u4e00-\u9fa5][\u4e00-\u9fa5\d\-]{4,40})')
        .firstMatch(text);
    if (receiveMatch != null) {
      var loc = receiveMatch.group(1) ?? '';
      if (loc.length >= 6 && !_isLogisticsNode(loc)) {
        return LocationParseResult(
          value: loc,
          type: LocationType.pickupStation,
          confidence: 0.88,
          source: 'receive_format',
        );
      }
    }

    // Priority 1: 地点标题格式1
    final title1Match = RegexPatterns.locationTitle1.firstMatch(text);
    if (title1Match != null) {
      var loc = TextPreprocessor.cleanLocation(title1Match.group(1)!.trim());
      if (loc.length >= 6 && !TextPreprocessor.isAdText(loc)) {
        final type = _determineLocationType(loc);
        // 如果是物流节点，不返回，继续尝试下一优先级
        if (type == LocationType.transitCenter) {
          // 跳过，继续尝试
        } else {
          return LocationParseResult(
            value: loc,
            type: type,
            confidence: type == LocationType.pickupStation ? 0.9 : 0.3,
            source: 'title_pattern_1',
          );
        }
      }
    }

    // Priority 2: 地点标题格式2
    final title2Match = RegexPatterns.locationTitle2.firstMatch(text);
    if (title2Match != null) {
      var loc = TextPreprocessor.cleanLocation(title2Match.group(1)!.trim());
      if (loc.length >= 6 && !TextPreprocessor.isAdText(loc)) {
        final type = _determineLocationType(loc);
        if (type == LocationType.transitCenter) {
          // 跳过，继续尝试
        } else {
          return LocationParseResult(
            value: loc,
            type: type,
            confidence: type == LocationType.pickupStation ? 0.85 : 0.3,
            source: 'title_pattern_2',
          );
        }
      }
    }

    // Priority 3: 到达格式
    final arrivalMatch = RegexPatterns.arrivalFormat.firstMatch(text);
    if (arrivalMatch != null) {
      var loc = arrivalMatch.group(1) ?? arrivalMatch.group(0) ?? '';
      loc = loc.replaceFirst(RegexPatterns.arrivalPrefix, '').trim();
      loc = TextPreprocessor.cleanLocation(loc);
      if (loc.length >= 3 && !TextPreprocessor.isAdText(loc)) {
        final type = _determineLocationType(loc);
        if (type == LocationType.transitCenter) {
          // 跳过，继续尝试
        } else {
          return LocationParseResult(
            value: loc,
            type: type,
            confidence: type == LocationType.pickupStation ? 0.8 : 0.3,
            source: 'arrival_format',
          );
        }
      }
    }

    // Priority 4: 关键词搜索
    String? bestLocation;
    var bestLength = 0;

    for (final kw in _pickupStationKeywords) {
      final idx = text.indexOf(kw);
      if (idx != -1) {
        final start = (idx - 30).clamp(0, text.length);
        var candidate = text.substring(start, idx + kw.length).trim();
        candidate = TextPreprocessor.cleanLocation(candidate);

        if (candidate.length > bestLength && 
            candidate.length >= 4 && 
            !TextPreprocessor.isAdText(candidate) &&
            !_isLogisticsNode(candidate)) {
          bestLocation = candidate;
          bestLength = candidate.length;
        }
      }
    }

    if (bestLocation != null) {
      return LocationParseResult(
        value: bestLocation,
        type: LocationType.pickupStation,
        confidence: 0.7,
        source: 'keyword_search',
      );
    }

    return LocationParseResult.empty();
  }

  /// 向后兼容的提取方法
  static ExtractionResult<String> extract(String text) {
    final result = extractTyped(text);
    return ExtractionResult(
      value: result.value,
      confidence: result.confidence,
      source: result.source,
    );
  }
}

/// 站点名称提取器
///
/// 从文本中识别站点名称（菜鸟驿站、丰巢等），作为 location 的 fallback。
class StationExtractor {
  static const _stationKeywords = [
    '菜鸟驿站', '丰巢', '快递柜', '妈妈驿站', '驿站',
    '菜鸟', '菜乌',
    '代收点', '营业部', '网点', '自提点', '服务点', '门店',
  ];

  /// 站点名称的 OCR 变体（只含可能出现在 location 开头的前缀）
  static const _stationPrefixVariants = [
    '菜鸟驿站', '菜鸟', '鸟一', '菜乌',
    '丰巢', '快递柜',
    '妈妈驿站', '妈妈',
    '驿站', '代收点', '营业部',
    '网点', '自提点', '服务点',
  ];

  /// 站点名称标准化映射
  static const Map<String, String> _stationNormalizeMap = {
    '菜鸟': '菜鸟驿站',
    '菜乌': '菜鸟驿站',
    '鸟一': '菜鸟驿站',
    '妈妈': '妈妈驿站',
  };

  /// 从文本中提取站点名称
  static String extract(String text) {
    for (final kw in _stationKeywords) {
      if (text.contains(kw)) {
        return _stationNormalizeMap[kw] ?? kw;
      }
    }
    return '';
  }

  /// 清除 location 开头残留的站点名称前缀（含 OCR 变体）
  static String cleanLocation(String location, String station) {
    if (location.isEmpty || station.isEmpty) return location;

    var cleaned = location;
    for (final variant in _stationPrefixVariants) {
      final idx = cleaned.indexOf(variant);
      if (idx >= 0 && idx <= 3) {
        cleaned = cleaned.substring(idx + variant.length);
        break;
      }
    }
    // 去掉开头残留的标点/符号
    cleaned = cleaned.replaceFirst(RegExp(r'^[·、，,.\s]+'), '');
    return cleaned;
  }
}

/// 运单号提取器
class TrackingNumberExtractor {
  /// 规范化运单号：去除多余空格、制表符
  static String _normalizeTrackingNumber(String number) {
    return number.replaceAll(RegExp(r'[\s\t]+'), '');
  }

  static ExtractionResult<String> extract(String text) {
    // Priority 1: 带标签的运单号
    final labelMatch = RegexPatterns.labeledTrackingNumber.firstMatch(text);
    if (labelMatch != null) {
      return ExtractionResult(
        value: _normalizeTrackingNumber(labelMatch.group(1)!),
        confidence: 0.95,
        source: 'labeled_tracking',
      );
    }

    // Priority 2: 快递公司+运单号（保留前缀）
    final courierMatch = RegexPatterns.courierTrackingNumber.firstMatch(text);
    if (courierMatch != null) {
      var fullMatch = courierMatch.group(0) ?? '';
      fullMatch = _normalizeTrackingNumber(fullMatch);
      final pureNumber = courierMatch.group(1) ?? fullMatch;
      return ExtractionResult(
        value: pureNumber.isNotEmpty ? _normalizeTrackingNumber(pureNumber) : fullMatch,
        confidence: 0.9,
        source: 'courier_tracking',
      );
    }

    // Priority 2.5: 宽松快递公司+运单号（短名称+数字，如"申通777407042267539"）
    final looseCourierMatch = RegexPatterns.looseCourierTrackingNumber.firstMatch(text);
    if (looseCourierMatch != null) {
      var fullMatch = looseCourierMatch.group(0) ?? '';
      fullMatch = _normalizeTrackingNumber(fullMatch);
      return ExtractionResult(
        value: fullMatch,
        confidence: 0.82,
        source: 'loose_courier_tracking',
      );
    }

    // Priority 3: 快递公司前缀（JT, YT, SF, ZTO等）
    final prefixPatterns = [
      RegexPatterns.jtTracking,
      RegexPatterns.sfTracking,
      RegexPatterns.jdTracking,
      RegexPatterns.yt88Tracking,
      RegexPatterns.ytTracking,
      RegexPatterns.ztoTracking,
      RegexPatterns.numericTracking,
    ];

    for (final pattern in prefixPatterns) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        final number = _normalizeTrackingNumber(match.group(0)!);
        if (!RegexPatterns.phoneNumber.hasMatch(number)) {
          return ExtractionResult(
            value: number,
            confidence: 0.85,
            source: 'courier_prefix',
          );
        }
      }
    }

    // Priority 4: 宽松长数字兜底（10-18位）
    final looseMatch = RegexPatterns.looseNumericTracking.firstMatch(text);
    if (looseMatch != null) {
      final number = _normalizeTrackingNumber(looseMatch.group(1)!);
      if (!RegexPatterns.phoneNumber.hasMatch(number)) {
        return ExtractionResult(
          value: number,
          confidence: 0.5,
          source: 'loose_numeric',
        );
      }
    }

    return ExtractionResult(
      value: '',
      confidence: 0.0,
      source: 'no_match',
    );
  }
}

/// 手机尾号提取器
class PhoneTailExtractor {
  static ExtractionResult<String> extract(String text) {
    // Pattern 1: 明确的手机尾号
    final tailMatch = RegexPatterns.explicitTail.firstMatch(text);
    if (tailMatch != null) {
      return ExtractionResult(
        value: tailMatch.group(1)!,
        confidence: 0.95,
        source: 'explicit_tail',
      );
    }

    // Pattern 2: 掩码手机号
    final maskedMatch = RegexPatterns.maskedPhone.firstMatch(text);
    if (maskedMatch != null) {
      return ExtractionResult(
        value: maskedMatch.group(1)!,
        confidence: 0.9,
        source: 'masked_phone',
      );
    }

    // Pattern 3: 完整手机号
    final phoneMatch = RegexPatterns.fullPhone.firstMatch(text);
    if (phoneMatch != null) {
      final full = phoneMatch.group(1)!;
      return ExtractionResult(
        value: full.substring(full.length - 4),
        confidence: 0.85,
        source: 'full_phone',
      );
    }

    // Pattern 4: 机主相关尾号
    final ownerMatch = RegexPatterns.ownerTail.firstMatch(text);
    if (ownerMatch != null) {
      return ExtractionResult(
        value: ownerMatch.group(1)!,
        confidence: 0.8,
        source: 'owner_tail',
      );
    }

    return ExtractionResult(
      value: '',
      confidence: 0.0,
      source: 'no_match',
    );
  }
}

/// 状态提取器（多信号验证）
/// 
/// arrived 判定需要多个信号同时满足：
/// - 取件码信号（取件码、取货码、提取码）
/// - 驿站/地点信号（驿站、营业部、网点、快递柜）
/// - 已到达信号（已到达、待取件、已入库）
/// - 取件动作信号（取件、提取、提货）
/// 
/// 重要：单独的数字或取件码不足以推断为 arrived
class StatusExtractor {
  /// UI角标过滤正则
  /// 匹配：待取件2、待取件 3、运输中2 等
  static final _uiBadgeRegex = RegExp(r'(?:待取件|运输中|派送中|已取件|运送中)\s*\d+');
  
  /// 提取状态
  static ExtractionResult<PackageStatus> extract(String text) {
    // 第一步：过滤UI角标
    final filteredText = text.replaceAll(_uiBadgeRegex, '');
    
    // 第二步：尝试匹配高置信度关键词（stageMap）
    final directMatch = _matchDirectKeywords(filteredText);
    if (directMatch != null) {
      return directMatch;
    }

    // 第三步：获取位置类型
    final locationResult = LocationExtractor.extractTyped(filteredText);
    
    // 第四步：多信号验证
    final signals = _analyzeSignals(filteredText, locationResult.type);
    return _determineBySignals(signals);
  }

  /// 状态优先级：rejected > pickedUp > delivering > arrived > transit > pendingShipment / archived
  static int _statusPriority(PackageStatus status) {
    switch (status) {
      case PackageStatus.rejected:
        return 5;
      case PackageStatus.pickedUp:
        return 4;
      case PackageStatus.delivering:
        return 3;
      case PackageStatus.arrived:
        return 2;
      case PackageStatus.transit:
        return 1;
      case PackageStatus.pendingShipment:
      case PackageStatus.archived:
        return 0;
    }
  }

  /// 匹配高置信度关键词
  static ExtractionResult<PackageStatus>? _matchDirectKeywords(String text) {
    PackageStatus? found;
    var bestLen = 0;
    var bestPriority = 0;

    for (final entry in StatusDictionary.stageMap.entries) {
      if (!text.contains(entry.key)) continue;
      final priority = _statusPriority(entry.value);
      // 优先按优先级排序，同优先级再按长度排序
      if (priority > bestPriority || (priority == bestPriority && entry.key.length > bestLen)) {
        found = entry.value;
        bestPriority = priority;
        bestLen = entry.key.length;
      }
    }

    // 特殊处理：如果包含"已到达" + 地点的情况
    if (found == null && text.contains('已到达')) {
      // 检查是否有地点关键词
      final hasStationKeyword = StatusDictionary.locationSignals.any((s) => text.contains(s));
      final hasPickupCode = StatusDictionary.pickupCodeSignals.any((s) => text.contains(s));
      if (hasStationKeyword || hasPickupCode) {
        return ExtractionResult(
          value: PackageStatus.arrived,
          confidence: 0.88,
          source: 'has_arrived_and_location',
        );
      }
    }

    if (found != null) {
      return ExtractionResult(
        value: found,
        confidence: 0.9,
        source: 'direct_keyword',
      );
    }

    return null;
  }

  /// 分析文本中的各种信号
  static StatusSignals _analyzeSignals(String text, LocationType locationType) {
    // 检查是否真的提取到了取件码（使用 PickupCodeExtractor）
    final pickupCodeResult = PickupCodeExtractor.extract(text);
    final hasExtractedPickupCode = pickupCodeResult.value.isNotEmpty && 
        pickupCodeResult.confidence >= 0.6; // 降低要求到 0.6
    
    // 检查是否包含取件码关键词
    final hasPickupCodeKeyword = _containsAny(text, StatusDictionary.pickupCodeSignals);
    
    // 取件码信号 = 真的提取到了取件码 OR 包含取件码关键词（放松条件！）
    final hasPickupCodeSignal = hasExtractedPickupCode || hasPickupCodeKeyword;
    
    // 地点信号 = 包含地点关键词 OR 位置类型为取件站点（放松条件！）
    final hasLocationKeyword = _containsAny(text, StatusDictionary.locationSignals);
    final hasLocationSignal = hasLocationKeyword || locationType == LocationType.pickupStation;
    
    return StatusSignals(
      hasPickupCodeSignal: hasPickupCodeSignal,
      hasLocationSignal: hasLocationSignal,
      hasArrivedSignal: _containsAny(text, StatusDictionary.arrivedSignals),
      hasPickupActionSignal: _containsAny(text, StatusDictionary.pickupActionSignals),
      hasPickedUpSignal: _containsAny(text, StatusDictionary.pickedUpSignals),
      hasDeliveringSignal: _containsAny(text, StatusDictionary.deliveringSignals),
      hasTransitSignal: _containsAny(text, StatusDictionary.transitSignals),
      hasBayFormat: StatusDictionary.bayFormatRegex.hasMatch(text),
      hasDigitCode: StatusDictionary.digitCodeRegex.hasMatch(text),
      locationType: locationType,
    );
  }

  /// 根据信号确定状态
  static ExtractionResult<PackageStatus> _determineBySignals(StatusSignals signals) {
    // ── 已取件判定 ──────────────────────────────────────────────
    // 签收/代收信号单独出现即可判定
    if (signals.hasPickedUpSignal) {
      return ExtractionResult(
        value: PackageStatus.pickedUp,
        confidence: 0.85,
        source: 'picked_up_signal',
      );
    }

    // ── 派送中判定 ──────────────────────────────────────────────
    // 派送/配送信号单独出现即可判定
    if (signals.hasDeliveringSignal) {
      return ExtractionResult(
        value: PackageStatus.delivering,
        confidence: 0.85,
        source: 'delivering_signal',
      );
    }

    // ── 已到达判定（优先于 transit！！！）────────────────────────────
    // 规则1：只要同时有取件码信号和地点信号，就直接判定 arrived！
    if (signals.hasPickupCodeSignal && signals.hasLocationSignal) {
      return ExtractionResult(
        value: PackageStatus.arrived,
        confidence: 0.88,
        source: 'pickupcode_and_location',
      );
    }

    // 规则2：检查 arrived 相关信号计数
    final arrivedSignalCount = signals.arrivedSignalCount;
    final hasEssentialSignal = signals.hasPickupCodeSignal || signals.hasLocationSignal;

    if (arrivedSignalCount >= 2 && hasEssentialSignal) {
      // 多信号满足，高置信度 arrived
      return ExtractionResult(
        value: PackageStatus.arrived,
        confidence: 0.8 + (arrivedSignalCount - 2) * 0.05,
        source: 'multi_signal_arrived',
      );
    }

    if (arrivedSignalCount == 1 && hasEssentialSignal) {
      // 单信号满足，中等置信度 arrived
      return ExtractionResult(
        value: PackageStatus.arrived,
        confidence: 0.6,
        source: 'single_signal_arrived',
      );
    }

    // ── 运送中判定 ──────────────────────────────────────────────
    // 揽收/运输信号单独出现即可判定（现在放在 arrived 之后！）
    if (signals.hasTransitSignal) {
      return ExtractionResult(
        value: PackageStatus.transit,
        confidence: 0.85,
        source: 'transit_signal',
      );
    }

    // ── 默认：运送中 ──────────────────────────────────────────
    // 没有任何信号时，默认为运送中（最保守的推断）
    return ExtractionResult(
      value: PackageStatus.transit,
      confidence: 0.4,
      source: 'default_transit',
    );
  }

  /// 检查文本是否包含列表中的任意关键词
  static bool _containsAny(String text, List<String> keywords) {
    return keywords.any((kw) => text.contains(kw));
  }
}

/// 状态信号分析结果
class StatusSignals {
  final bool hasPickupCodeSignal;   // 取件码信号（真的提取到了取件码 AND 包含关键词）
  final bool hasLocationSignal;     // 驿站/地点信号（且位置类型为取件站点）
  final bool hasArrivedSignal;      // 已到达信号
  final bool hasPickupActionSignal; // 取件动作信号
  final bool hasPickedUpSignal;     // 已取件信号
  final bool hasDeliveringSignal;   // 派送中信号
  final bool hasTransitSignal;      // 运送中信号
  final bool hasBayFormat;          // Bay 格式取件码
  final bool hasDigitCode;          // 纯数字取件码
  final LocationType locationType;  // 位置类型

  const StatusSignals({
    required this.hasPickupCodeSignal,
    required this.hasLocationSignal,
    required this.hasArrivedSignal,
    required this.hasPickupActionSignal,
    required this.hasPickedUpSignal,
    required this.hasDeliveringSignal,
    required this.hasTransitSignal,
    required this.hasBayFormat,
    required this.hasDigitCode,
    this.locationType = LocationType.unknown,
  });

  /// arrived 相关信号数量
  int get arrivedSignalCount {
    int count = 0;
    if (hasPickupCodeSignal) count++;
    if (hasLocationSignal) count++;
    if (hasArrivedSignal) count++;
    if (hasPickupActionSignal) count++;
    if (hasBayFormat) count++;
    return count;
  }
}
