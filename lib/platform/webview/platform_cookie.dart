/// 平台会话 Cookie 注入工具
///
/// 与 `WebViewCookieManager.setCookie` 的差别：原生 `CookieManager.setCookie(url, cookie)`
/// 接受完整的 Cookie 头字符串，可携带 `HttpOnly` / `Secure` 属性，
/// 而 Dart 侧 `WebViewCookie` 只能传 name/value/path，
/// 会把平台原本的 HttpOnly 会话令牌变成页面脚本可读，削弱平台侧防护。
///
/// 因此优先走原生通道；在不可用时回退到 Dart 侧写入（不携带安全属性）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

const MethodChannel _webviewChannel =
    MethodChannel('com.example.pickup_app/webview_hook');

/// 以原生方式写入单条 Cookie（保留 HttpOnly/Secure）
Future<bool> setPlatformCookie({
  required String name,
  required String value,
  required String domain,
  bool httpOnly = true,
  bool secure = true,
}) async {
  if (name.isEmpty || value.isEmpty || domain.isEmpty) return false;
  final host = domain.startsWith('.') ? domain.substring(1) : domain;
  final url = 'https://$host/';
  final cookie = StringBuffer('$name=$value; Path=/; Domain=$domain');
  if (secure) cookie.write('; Secure');
  if (httpOnly) cookie.write('; HttpOnly');

  try {
    final ok = await _webviewChannel.invokeMethod<bool>('setCookie', {
      'url': url,
      'cookie': cookie.toString(),
    });
    if (ok == true) return true;
  } catch (e) {
    debugPrint('[Cookie] native setCookie failed, fallback to Dart: $e');
  }

  try {
    await WebViewCookieManager().setCookie(
      WebViewCookie(domain: domain, path: '/', name: name, value: value),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// 把一整串 `k=v; k2=v2` Cookie 写入指定域名集合
Future<void> injectCookieString({
  required String cookies,
  required List<String> domains,
  bool httpOnly = true,
  bool secure = true,
}) async {
  for (final part in cookies.split(';')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final name = part.substring(0, idx).trim();
    final value = part.substring(idx + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    for (final domain in domains) {
      await setPlatformCookie(
        name: name,
        value: value,
        domain: domain,
        httpOnly: httpOnly,
        secure: secure,
      );
    }
  }
}
