/// 同步互踢诊断：把「登录」与「访问」严格分开，用受控步骤判断会话冲突的触发点。
///
/// 设计原则：
/// - 只记录 Cookie 的名称、数量、总长度与整串指纹（SHA-256 前 12 位），绝不记录真实令牌值；
/// - 每一步都用「全新的 WebView + 清空后的 Cookie 存储」，以区分「新建 WebView 是否等于新会话」；
/// - 步骤之间互不干扰，结果只读不改写已保存的登录凭据。
library;

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../storage/platform_auth_store.dart';

/// 诊断步骤的类型
enum DiagStepKind {
  /// 仅加载首页（不触发订单相关接口）
  homeOnly,

  /// 加载订单页（页面本身会拉取订单列表）
  ordersPage,

  /// 加载订单页并显式调用订单接口
  ordersApi,
}

class DiagStepResult {
  final String step;
  final String injectedFingerprint;
  final String afterFingerprint;
  final int injectedCount;
  final int afterCount;
  final String landedUrl;
  final bool pageLoaded;
  final bool authOk;
  final String apiStatus;
  final int elapsedMs;
  final String note;

  const DiagStepResult({
    required this.step,
    required this.injectedFingerprint,
    required this.afterFingerprint,
    required this.injectedCount,
    required this.afterCount,
    required this.landedUrl,
    required this.pageLoaded,
    required this.authOk,
    required this.apiStatus,
    required this.elapsedMs,
    required this.note,
  });

  bool get rotated => injectedFingerprint != afterFingerprint;
}

class DiagReport {
  final DateTime startedAt;
  final String storedFingerprint;
  final int storedCount;
  final int storedLength;
  final String tokenNames;
  final List<DiagStepResult> steps;

  const DiagReport({
    required this.startedAt,
    required this.storedFingerprint,
    required this.storedCount,
    required this.storedLength,
    required this.tokenNames,
    required this.steps,
  });

  String toText() {
    final b = StringBuffer();
    b.writeln('===== 拼多多同步诊断报告 =====');
    b.writeln('时间: ${startedAt.toIso8601String()}');
    b.writeln('已保存凭据: 指纹=$storedFingerprint 条数=$storedCount 长度=$storedLength');
    b.writeln('关键令牌名称: ${tokenNames.isEmpty ? "（未发现）" : tokenNames}');
    b.writeln('');
    for (final s in steps) {
      b.writeln('--- ${s.step} ---');
      b.writeln('注入后指纹: ${s.injectedFingerprint} (${s.injectedCount} 条)');
      b.writeln('访问后指纹: ${s.afterFingerprint} (${s.afterCount} 条)');
      b.writeln('是否发生令牌轮换: ${s.rotated ? "是" : "否"}');
      b.writeln('落地 URL: ${s.landedUrl}');
      b.writeln('页面是否成功加载: ${s.pageLoaded ? "是" : "否"}');
      b.writeln('登录态是否有效: ${s.authOk ? "有效" : "已失效/被要求登录"}');
      if (s.apiStatus.isNotEmpty) b.writeln('订单接口结果: ${s.apiStatus}');
      b.writeln('耗时: ${s.elapsedMs}ms');
      if (s.note.isNotEmpty) b.writeln('备注: ${s.note}');
      b.writeln('');
    }
    b.writeln('===== 报告结束 =====');
    return b.toString();
  }
}

class SyncDiagnostics {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  static const _hosts = ['https://mobile.yangkeduo.com', 'https://yangkeduo.com'];

  Completer<String>? _bridgeCompleter;

  Future<DiagReport> runPddDiagnostics({
    void Function(String message)? onProgress,
  }) async {
    final store = PlatformAuthStore();
    final stored = store.getCookies('pdd') ?? '';

    final report = DiagReport(
      startedAt: DateTime.now(),
      storedFingerprint: _fingerprint(stored),
      storedCount: _countOf(stored),
      storedLength: stored.length,
      tokenNames: _tokenNames(stored),
      steps: [],
    );

    final steps = <DiagStepResult>[];
    for (final kind in DiagStepKind.values) {
      onProgress?.call('正在执行：${_stepLabel(kind)}');
      final r = await _runStep(kind, stored);
      steps.add(r);
      await Future.delayed(const Duration(milliseconds: 800));
    }

    return DiagReport(
      startedAt: report.startedAt,
      storedFingerprint: report.storedFingerprint,
      storedCount: report.storedCount,
      storedLength: report.storedLength,
      tokenNames: report.tokenNames,
      steps: steps,
    );
  }

  String _stepLabel(DiagStepKind kind) {
    switch (kind) {
      case DiagStepKind.homeOnly:
        return '步骤 1：全新 WebView，仅加载首页（不触发订单接口）';
      case DiagStepKind.ordersPage:
        return '步骤 2：全新 WebView，加载订单页（页面自身会拉订单）';
      case DiagStepKind.ordersApi:
        return '步骤 3：全新 WebView，加载订单页并显式调用订单接口';
    }
  }

  Future<DiagStepResult> _runStep(DiagStepKind kind, String stored) async {
    final sw = Stopwatch()..start();
    final cookieManager = WebViewCookieManager();

    // 1) 清空 WebView Cookie 存储，保证每一步都是干净起点
    try {
      await cookieManager.clearCookies();
    } catch (_) {}

    // 2) 注入已保存凭据
    await _inject(stored);
    final injected = await _readCookies();

    // 3) 新建 WebView 并加载页面
    final completer = Completer<String>();
    _bridgeCompleter = completer;

    var mainFrameError = '';
    var landedUrl = '';
    var authOk = false;
    var pageLoaded = false;
    var apiStatus = '';
    var note = '';
    var loadedOnFirstTry = true;

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      ..addJavaScriptChannel(
        'DiagBridge',
        onMessageReceived: (JavaScriptMessage m) {
          final c = _bridgeCompleter;
          if (c != null && !c.isCompleted) c.complete(m.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final lower = request.url.toLowerCase();
            // 诊断期间拦截外部 App 跳转，避免打断实验
            if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            // 记录主框架错误（子资源错误忽略），用于区分网络问题与登录态问题
            if (error.isForMainFrame ?? false) {
              mainFrameError = '${error.errorCode} ${error.description}';
              debugPrint('[Diag] main frame error: $mainFrameError');
            }
          },
        ),
      );

    try {
      final url = kind == DiagStepKind.homeOnly
          ? 'https://mobile.yangkeduo.com/'
          : 'https://mobile.yangkeduo.com/orders.html';

      Future<void> loadOnce() async {
        mainFrameError = '';
        await controller.loadRequest(Uri.parse(url));
        await _waitPageReady(controller);
      }

      await loadOnce();
      landedUrl = await _locationHref(controller);
      pageLoaded = _isPageLoaded(landedUrl);

      // 主框架加载失败时重试一次，区分「网络/风控问题」与「登录态问题」
      if (!pageLoaded) {
        loadedOnFirstTry = false;
        await Future.delayed(const Duration(seconds: 1));
        await loadOnce();
        landedUrl = await _locationHref(controller);
        pageLoaded = _isPageLoaded(landedUrl);
      }

      authOk = pageLoaded &&
          !landedUrl.contains('login') &&
          !landedUrl.contains('passport');

      if (!pageLoaded) {
        note = '页面未能加载（主框架错误：${mainFrameError.isEmpty ? "未知" : mainFrameError}），'
            '无法据此判断登录态，本步结果不参与结论';
      }

      switch (kind) {
        case DiagStepKind.homeOnly:
          if (pageLoaded) note = '本步骤不访问任何订单相关接口';
          break;
        case DiagStepKind.ordersPage:
          if (pageLoaded) {
            if (loadedOnFirstTry) {
              await Future.delayed(const Duration(seconds: 3));
              landedUrl = await _locationHref(controller);
              pageLoaded = _isPageLoaded(landedUrl);
              authOk = pageLoaded && !landedUrl.contains('login');
              note = '页面自身会请求订单列表，用于判断「普通页面访问」是否触发冲突';
            } else {
              note = '页面在第二次尝试后才加载成功，结果仅供参考';
            }
          }
          break;
        case DiagStepKind.ordersApi:
          if (pageLoaded) {
            apiStatus = await _callOrderApi(controller);
          } else {
            apiStatus = '（页面未加载，跳过接口调用）';
          }
          break;
      }
    } catch (e) {
      note = '执行异常: $e';
    } finally {
      if (identical(_bridgeCompleter, completer)) _bridgeCompleter = null;
    }

    // 4) 读取访问后的 Cookie 指纹
    final after = await _readCookies();

    return DiagStepResult(
      step: _stepLabel(kind),
      injectedFingerprint: _fingerprint(injected),
      afterFingerprint: _fingerprint(after),
      injectedCount: _countOf(injected),
      afterCount: _countOf(after),
      landedUrl: landedUrl,
      pageLoaded: pageLoaded,
      authOk: authOk,
      apiStatus: apiStatus,
      elapsedMs: sw.elapsedMilliseconds,
      note: note,
    );
  }

  /// 页面是否真正加载成功（排除 WebView 错误页）
  bool _isPageLoaded(String url) {
    if (url.trim().isEmpty) return false;
    final lower = url.toLowerCase();
    if (lower.startsWith('chrome-error') || lower.startsWith('about:')) return false;
    if (lower.startsWith('http') ) return true;
    return false;
  }

  Future<String> _callOrderApi(WebViewController controller) async {
    final completer = Completer<String>();
    _bridgeCompleter = completer;
    try {
      await controller.runJavaScript('''
(function(){
  function report(t){ try { DiagBridge.postMessage(String(t)); } catch(e) {} }
  try {
    var uid = '';
    var m = document.cookie.match(/(?:pdd_user_id|pdduid)=([^;]+)/);
    if (m) uid = m[1];
    var url = '/proxy/api/api/aristotle/order_list_v4?pdduid=' + uid + '&page=1&type=all';
    window.__diagApi = 'pending';
    fetch(url, {credentials:'include'}).then(function(r){
      window.__diagApi = 'HTTP:' + r.status;
      return r.text();
    }).then(function(t){
      report('HTTP:' + (window.__diagApi || '?') + '|BODY_LEN:' + t.length);
    }).catch(function(e){
      report('FETCH_ERROR:' + String(e) + '|URL:' + location.href);
    });
  } catch(e) { report('JS_ERROR:' + String(e)); }
})();
''');
      return await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => 'TIMEOUT',
      );
    } catch (e) {
      return 'EXCEPTION:$e';
    } finally {
      _bridgeCompleter = null;
    }
  }

  Future<void> _waitPageReady(WebViewController controller) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await controller.runJavaScriptReturningResult(
          "(function(){return (document.readyState==='complete') ? '1' : '0';})()",
        );
        if (r.toString().contains('1')) break;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 250));
    }
    // 站点会话校验与重定向的缓冲时间
    await Future.delayed(const Duration(milliseconds: 1200));
  }

  Future<String> _locationHref(WebViewController controller) async {
    try {
      final r = await controller.runJavaScriptReturningResult('location.href');
      var s = r.toString();
      if (s.startsWith('"') && s.endsWith('"')) {
        try {
          s = jsonDecode(s) as String;
        } catch (_) {
          s = s.substring(1, s.length - 1);
        }
      }
      return s;
    } catch (_) {
      return '';
    }
  }

  Future<void> _inject(String cookies) async {
    if (cookies.trim().isEmpty) return;
    final cm = WebViewCookieManager();
    for (final part in cookies.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final name = part.substring(0, idx).trim();
      final value = part.substring(idx + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      for (final host in const ['mobile.yangkeduo.com', 'yangkeduo.com', '.yangkeduo.com']) {
        try {
          await cm.setCookie(WebViewCookie(domain: host, path: '/', name: name, value: value));
        } catch (_) {}
      }
    }
  }

  Future<String> _readCookies() async {
    final cm = WebViewCookieManager();
    final map = <String, String>{};
    for (final host in _hosts) {
      try {
        final list = await cm.getCookies(domain: Uri.parse(host));
        for (final c in list) {
          if (c.name.isNotEmpty && c.value.isNotEmpty) map[c.name] = c.value;
        }
      } catch (_) {}
    }
    final sorted = map.keys.toList()..sort();
    return sorted.map((k) => '$k=${map[k]}').join('; ');
  }

  /// Cookie 整串指纹（仅用于判断是否轮换，不泄露原值）
  String _fingerprint(String cookies) {
    if (cookies.trim().isEmpty) return '(空)';
    return sha256.convert(utf8.encode(cookies)).toString().substring(0, 12);
  }

  int _countOf(String cookies) {
    if (cookies.trim().isEmpty) return 0;
    return cookies.split(';').where((e) => e.trim().isNotEmpty).length;
  }

  String _tokenNames(String cookies) {
    const markers = [
      'PDDAccessToken',
      'pdd_user_id',
      'pdduid',
      'AccessToken',
      'uniqid',
      'SUB_PASS_ID',
      'api_uid',
    ];
    final found = <String>[];
    for (final m in markers) {
      if (cookies.contains('$m=')) found.add(m);
    }
    return found.join(', ');
  }
}
