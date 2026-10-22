/// 文本清理器
/// 
/// 职责：
/// 1. 对 OCR 文本进行清理
/// 2. 过滤噪音行
/// 3. 保留有效物流信息
library;

import 'line_classifier.dart';
import 'logistics_keywords.dart';

/// 文本清理器
class TextSanitizer {
  /// 清理 OCR 文本
  /// 
  /// 流程：
  /// 1. 按行分割
  /// 2. 分类每一行
  /// 3. 过滤噪音行
  /// 4. 保留物流信息行
  /// 5. 重新组合
  static String clean(String rawText) {
    if (rawText.isEmpty) return rawText;

    final lines = rawText.split('\n');
    final cleanedLines = <String>[];

    for (final line in lines) {
      final analysis = LineClassifier.analyze(line);
      
      // 保留物流信息行，过滤噪音行
      if (analysis.isLogisticsInfo || analysis.type == LineType.address || analysis.type == LineType.contact) {
        cleanedLines.add(line.trim());
      }
    }

    // 如果清理后没有有效行，返回原始文本
    if (cleanedLines.isEmpty) {
      return rawText;
    }

    return cleanedLines.join('\n');
  }

  /// 清理文本并返回分析结果
  static SanitizedResult cleanWithAnalysis(String rawText) {
    if (rawText.isEmpty) {
      return SanitizedResult(
        original: rawText,
        cleaned: rawText,
        lineAnalyses: [],
        keptLines: 0,
        removedLines: 0,
      );
    }

    final lines = rawText.split('\n');
    final analyses = <LineAnalysis>[];
    final keptLines = <String>[];
    int removedCount = 0;

    for (final line in lines) {
      final analysis = LineClassifier.analyze(line);
      analyses.add(analysis);

      if (analysis.isLogisticsInfo || analysis.type == LineType.address || analysis.type == LineType.contact) {
        keptLines.add(line.trim());
      } else {
        removedCount++;
      }
    }

    final cleaned = keptLines.isEmpty ? rawText : keptLines.join('\n');

    return SanitizedResult(
      original: rawText,
      cleaned: cleaned,
      lineAnalyses: analyses,
      keptLines: keptLines.length,
      removedLines: removedCount,
    );
  }

  /// 提取物流相关文本
  static String extractLogisticsText(String rawText) {
    if (rawText.isEmpty) return rawText;

    final lines = rawText.split('\n');
    final logisticsLines = <String>[];

    for (final line in lines) {
      final analysis = LineClassifier.analyze(line);
      if (analysis.isLogisticsInfo) {
        logisticsLines.add(line.trim());
      }
    }

    return logisticsLines.join('\n');
  }

  /// 检查文本是否包含有效物流信息
  static bool hasValidLogisticsInfo(String text) {
    return LogisticsKeywords.containsLogistics(text);
  }

  /// 轻量熔断：检测 Dashboard / 首页截图
  ///
  /// 条件：文本短 + 含导航词（首页/设置/路线/我的/消息中心）
  /// 不依赖 ConflictAnalyzer，可独立测试
  static bool shouldAbortParse(String sanitizedText) {
    if (sanitizedText.length >= 50) return false;
    const dashboardKeywords = ['首页', '设置', '路线', '我的', '消息中心'];
    return dashboardKeywords.any((kw) => sanitizedText.contains(kw));
  }
}

/// 清理结果
class SanitizedResult {
  /// 原始文本
  final String original;
  
  /// 清理后的文本
  final String cleaned;
  
  /// 行分析结果
  final List<LineAnalysis> lineAnalyses;
  
  /// 保留的行数
  final int keptLines;
  
  /// 移除的行数
  final int removedLines;

  const SanitizedResult({
    required this.original,
    required this.cleaned,
    required this.lineAnalyses,
    required this.keptLines,
    required this.removedLines,
  });

  /// 是否有有效内容
  bool get hasValidContent => keptLines > 0;

  /// 获取噪音行
  List<LineAnalysis> get noiseLines => 
      lineAnalyses.where((a) => a.isNoise).toList();

  /// 获取物流信息行
  List<LineAnalysis> get logisticsLines => 
      lineAnalyses.where((a) => a.isLogisticsInfo).toList();
}
