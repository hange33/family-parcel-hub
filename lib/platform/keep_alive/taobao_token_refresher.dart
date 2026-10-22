/// 淘宝 mtop 令牌轮换器（纯 Dart，前后台通用）
///
/// 从 `taobao_connector.dart` 的 `_mtopCall` 抽取的轻量续期逻辑：
/// 发起一次菜鸟 `getTimeStamp` 请求，轮换 `_m_h5_tk` / `_m_h5_tk_enc` 令牌，
/// 并判断登录态是否失效。前台心跳与后台 Worker 共用，不依赖连接器状态。
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 一次令牌轮换请求的结局。
///
/// 三种互斥结局由字段表达：成功（newToken/newTokenEnc 非空）、
/// 会话失效（sessionExpired）、网络错误（networkError）。
class MtopRefreshResult {
  final String? newToken;
  final String? newTokenEnc;
  final bool sessionExpired;
  final bool networkError;

  const MtopRefreshResult({
    this.newToken,
    this.newTokenEnc,
    this.sessionExpired = false,
    this.networkError = false,
  });

  /// 是否发生了令牌轮换
  bool get rotated => newToken != null || newTokenEnc != null;
}

class TaobaoTokenRefresher {
  static const _appKey = '12574478';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  /// 发起轻量 mtop 请求并轮换令牌。
  ///
  /// [cookies] 为当前存储的完整 Cookie 串。返回结果由调用方负责落盘：
  /// - `newToken`/`newTokenEnc` 非空时用 `PlatformAuthStore.updateCookieTokenFields` 更新，
  /// - `sessionExpired` 为 true 时标记登录态失效。
  static Future<MtopRefreshResult> refresh(String cookies) async {
    final client = http.Client();
    try {
      var cookieStr = cookies;
      for (var attempt = 0; attempt < 2; attempt++) {
        final tokenMatch = RegExp(r'_m_h5_tk=([^;]+)').firstMatch(cookieStr);
        final token = tokenMatch?.group(1)?.split('_').first ?? '';

        const dataRaw = '{"stationType":"XY"}';
        final t = DateTime.now().millisecondsSinceEpoch.toString();
        final signSource = '$token&$t&$_appKey&$dataRaw';
        final sign = md5.convert(utf8.encode(signSource)).toString();

        final url =
            'https://h5api.m.taobao.com/h5/mtop.cainiao.pickup.search.getTimeStamp/1.0/?jsv=2.3.18&appKey=$_appKey&t=$t&sign=$sign&type=jsonp&dataType=jsonp&data=${Uri.encodeComponent(dataRaw)}';

        final resp = await client.get(
          Uri.parse(url),
          headers: {
            'User-Agent': _ua,
            'Origin': 'https://h5.m.taobao.com',
            'Referer': 'https://h5.m.taobao.com/',
            'Cookie': cookieStr,
          },
        ).timeout(const Duration(seconds: 10));

        final setCookies = resp.headers['set-cookie'] ?? '';
        final newTk =
            RegExp(r'_m_h5_tk=([^;]+)').firstMatch(setCookies)?.group(1);
        final newTkEnc =
            RegExp(r'_m_h5_tk_enc=([^;]+)').firstMatch(setCookies)?.group(1);
        if (newTk != null || newTkEnc != null) {
          var updated = cookieStr;
          if (newTk != null) {
            updated = updated.contains('_m_h5_tk=')
                ? updated.replaceAll(RegExp(r'_m_h5_tk=[^;]*'), '_m_h5_tk=$newTk')
                : '$updated; _m_h5_tk=$newTk';
          }
          if (newTkEnc != null) {
            updated = updated.contains('_m_h5_tk_enc=')
                ? updated.replaceAll(
                    RegExp(r'_m_h5_tk_enc=[^;]*'), '_m_h5_tk_enc=$newTkEnc')
                : '$updated; _m_h5_tk_enc=$newTkEnc';
          }
          cookieStr = updated;
        }

        final body = resp.body;
        if (body.contains('FAIL_SYS_SESSION_EXPIRED') ||
            body.contains('FAIL_SYS_SID_INVALID') ||
            body.contains('您需要登录才能继续访问')) {
          return MtopRefreshResult(
            newToken: newTk,
            newTokenEnc: newTkEnc,
            sessionExpired: true,
          );
        }

        final isTokenErr = body.contains('FAIL_SYS_TOKEN_EMPTY') ||
            body.contains('FAIL_SYS_TOKEN_EXPIRED');
        if (isTokenErr) {
          if (attempt < 1) {
            await Future.delayed(const Duration(milliseconds: 150));
            continue;
          }
          return const MtopRefreshResult(sessionExpired: true);
        }

        return MtopRefreshResult(newToken: newTk, newTokenEnc: newTkEnc);
      }
      return const MtopRefreshResult();
    } catch (_) {
      return const MtopRefreshResult(networkError: true);
    } finally {
      client.close();
    }
  }
}
