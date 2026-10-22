/// 一键诊断：把「登录态现状 + 抓取现场」拼成一段可复制的文本
///
/// 为什么需要它：release 包不能连 adb，用户又找不到日志时，
/// 让 App 自己把关键状态吐出来，比反复猜快得多。
library;

import '../storage/platform_auth_store.dart';
import 'pdd_parse_diag.dart';

class HubDiag {
  static List<String> cookieNames(String cookieStr) {
    final out = <String>[];
    for (final part in cookieStr.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final n = part.substring(0, idx).trim();
      if (n.isNotEmpty) out.add(n);
    }
    return out;
  }

  static Future<String> build({String? lastIssue}) async {
    final store = PlatformAuthStore();
    final pdd = store.getCookies('pdd') ?? '';
    final names = cookieNames(pdd);
    final bound = store.isBound('pdd');
    final expired = store.isExpired('pdd');
    final entry = store.getEntryUrl('pdd') ?? '';

    final b = StringBuffer()
      ..writeln('=== 家庭聚合诊断 ===')
      ..writeln('时间: ${DateTime.now().toString().substring(0, 19)}')
      ..writeln('拼多多 已绑定: $bound ｜ 失效标记: $expired')
      ..writeln('已存凭据: ${pdd.length} 字 / ${names.length} 条')
      ..writeln('Cookie 名: ${names.isEmpty ? "（空）" : names.join(", ")}')
      ..writeln('记录入口: ${entry.isEmpty ? "（无）" : entry}')
      ..writeln('上次同步问题: ${lastIssue ?? "无"}')
      ..writeln();

    if (!bound || pdd.isEmpty) {
      b.writeln('⚠️ 本地没有任何拼多多凭据 —— 说明「绑定」这一步没存进去。');
      b.writeln('   请回设置 → 拼多多 → 页面登录后点底部「已在页面完成登录，点击绑定账号」。');
      b.writeln();
    }

    b.write(PddParseDiag.dump());
    return b.toString();
  }
}
