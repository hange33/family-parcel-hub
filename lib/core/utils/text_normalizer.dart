/// 文本规范化工具 - 纯Dart
/// 
/// 职责：
/// 1. 对文本进行规范化处理
/// 2. 生成文本指纹（fingerprint）
/// 3. 用于 transit 阶段的弱身份标识
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';

/// 文本规范化工具
class TextNormalizer {
  /// 规范化文本
  /// 
  /// 删除：
  /// - 数字
  /// - 时间（如 12:34）
  /// - 日期（如 2024-05-09）
  /// - 标点符号
  /// - 空格
  /// - 特殊字符
  static String normalize(String text) {
    var normalized = text;
    
    // 删除时间格式（12:34, 12:34:56）
    normalized = normalized.replaceAll(RegExp(r'\d{1,2}:\d{2}(:\d{2})?'), '');
    
    // 删除日期格式（2024-05-09, 2024/05/09, 05-09, 05/09）
    normalized = normalized.replaceAll(RegExp(r'\d{4}[-/]\d{1,2}[-/]\d{1,2}'), '');
    normalized = normalized.replaceAll(RegExp(r'\d{1,2}[-/]\d{1,2}'), '');
    
    // 删除纯数字
    normalized = normalized.replaceAll(RegExp(r'\d+'), '');
    
    // 删除标点符号和特殊字符
    normalized = normalized.replaceAll(RegExp(r'[，。！？、；：""''（）【】《》\s\.\,\!\?\;\:\'\"\(\)\[\]\{\}\-\_\+\=\@\#\$\%\^\&\*\~\`]'), '');
    
    // 删除多余空格
    normalized = normalized.replaceAll(RegExp(r'\s+'), '');
    
    return normalized;
  }

  /// 生成文本指纹
  /// 
  /// 使用 MD5 哈希算法
  /// 输入：规范化后的文本
  /// 输出：32位十六进制字符串
  static String fingerprint(String text) {
    final normalized = normalize(text);
    final bytes = utf8.encode(normalized);
    final hash = md5.convert(bytes);
    return hash.toString();
  }

  /// 生成 Package 的 transit 指纹
  ///
  /// 基于 courier + trackingNumber + normalizedText
  /// trackingNumber 确保不同单号不会产生相同 fingerprint
  static String? transitFingerprint(
    String courierName,
    String rawText, {
    String? trackingNumber,
  }) {
    final normalized = normalize(rawText);

    // 安全保护：避免 OCR 异常导致 fingerprint 全部相同
    if (courierName.isEmpty || normalized.length < 5) {
      return null;
    }

    final trackingPart = trackingNumber ?? '';
    final combined = '$courierName|$trackingPart|$normalized';
    final bytes = utf8.encode(combined);
    final hash = md5.convert(bytes);
    return hash.toString();
  }

  /// 比较两个文本是否相同（忽略数字、时间、标点）
  static bool isTextSimilar(String text1, String text2) {
    final normalized1 = normalize(text1);
    final normalized2 = normalize(text2);
    return normalized1 == normalized2;
  }
}
