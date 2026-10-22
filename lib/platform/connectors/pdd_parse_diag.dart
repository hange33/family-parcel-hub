/// 拼多多抓取诊断缓存
///
/// 目的：真机上解析不对时，让用户一键复制「每个候选页的原文 + 命中/丢弃明细」发出来，
/// 不必连 adb、不必装 debug 包。页面原文是唯一的真相来源，先拿到它再谈解析。
library;

class PddParseDiag {
  /// 各候选页的正文样本（url → text）
  static final Map<String, String> pageSamples = <String, String>{};

  static String lastParsedUrl = '';
  static String lastUserAgent = '';
  static int lastLineCount = 0;
  static int acceptedCount = 0;
  static final List<String> rejectedSamples = <String>[];
  static final List<String> attemptLog = <String>[];
  static String updatedAt = '';

  /// 最近一次登录采集到的 Cookie 名（只有名字，没有值）
  static List<String> lastCookieNames = <String>[];

  static const int _perPageLimit = 5000;

  static void recordPage(String url, String text) {
    pageSamples[url] = text.length > _perPageLimit
        ? text.substring(0, _perPageLimit)
        : text;
    attemptLog.add('$url → ${text.length} 字');
    updatedAt = DateTime.now().toString().substring(0, 19);
  }

  static void recordParse({
    required String url,
    required int lineCount,
    required int accepted,
    required List<String> rejected,
    required String userAgent,
  }) {
    lastParsedUrl = url;
    lastLineCount = lineCount;
    acceptedCount = accepted;
    rejectedSamples
      ..clear()
      ..addAll(rejected.take(12));
    lastUserAgent = userAgent;
    updatedAt = DateTime.now().toString().substring(0, 19);
  }

  static String dump() {
    final b = StringBuffer()
      ..writeln('=== 拼多多抓取诊断 ===')
      ..writeln('时间: $updatedAt')
      ..writeln('UA: ${lastUserAgent.isEmpty ? "（未记录）" : lastUserAgent}')
      ..writeln('解析页: ${lastParsedUrl.isEmpty ? "（未记录）" : lastParsedUrl}')
      ..writeln('页面行数: $lastLineCount ｜ 命中包裹: $acceptedCount')
      ..writeln('登录采集到的 Cookie 名: ${lastCookieNames.isEmpty ? "（无）" : lastCookieNames.join(", ")}');

    if (attemptLog.isNotEmpty) {
      b.writeln('--- 尝试过的页面 ---');
      for (final a in attemptLog) {
        b.writeln('· $a');
      }
    }
    if (rejectedSamples.isNotEmpty) {
      b.writeln('--- 被丢弃的候选（疑似型号/已取件）---');
      for (final s in rejectedSamples) {
        b.writeln('· $s');
      }
    }
    for (final entry in pageSamples.entries) {
      b
        ..writeln()
        ..writeln('--- 页面原文：${entry.key} ---')
        ..writeln(entry.value);
    }
    if (pageSamples.isEmpty) {
      b.writeln('（还没有抓取过页面，请先回首页下拉同步一次）');
    }
    return b.toString();
  }
}
