/// 拼多多内置移动端容器
///
/// 核心解决：
/// 1. 拼多多单设备会话互踢痛点：用户可直接在本应用内完成拼多多的完整浏览、下单、查看订单与物流；
///    无需在手机上安装或打开拼多多官方 App，彻底避免双端互踢。
/// 2. 自动化物流同步：拦截外部 App Scheme，保持登录态持久化，在进入订单中心或点击同步时
///    自动聚合在途包裹与取件码至应用主页。
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../core/models/package.dart';
import '../../../core/models/package_status.dart';
import '../../../platform/connectors/connector_manager.dart';
import '../../../platform/connectors/pdd_connector.dart';
import '../../../platform/storage/platform_auth_store.dart';
import '../../../platform/webview/platform_cookie.dart';
import '../../providers/package_provider.dart';

class PddWebScreen extends ConsumerStatefulWidget {
  final String? initialUrl;

  const PddWebScreen({super.key, this.initialUrl});

  static Future<void> open(BuildContext context, {String? url}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PddWebScreen(initialUrl: url),
      ),
    );
  }

  /// 解析 Android Intent 格式的 URL，还原出真实的 Scheme 协议（如 alipays:// 或 weixin://）
  @visibleForTesting
  static String? parseIntentUrl(String intentUrl) {
    try {
      final hashIdx = intentUrl.indexOf('#Intent;');
      if (hashIdx == -1) return null;

      final mainPart = intentUrl.substring(0, hashIdx);
      final paramsPart = intentUrl.substring(hashIdx + '#Intent;'.length);
      final params = paramsPart.split(';');

      String? scheme;
      String? package;
      for (final p in params) {
        final kv = p.split('=');
        if (kv.length >= 2) {
          final k = kv[0].trim();
          final v = kv.sublist(1).join('=').trim();
          if (k == 'scheme') {
            scheme = v;
          } else if (k == 'package') {
            package = v;
          }
        }
      }

      // 如果未显式提供 scheme 但指定了支付宝包名
      if ((scheme == null || scheme.isEmpty) && package == 'com.eg.android.AlipayGphone') {
        scheme = 'alipays';
      }

      if (scheme != null && scheme.isNotEmpty) {
        if (mainPart.startsWith('intent://')) {
          return '$scheme://${mainPart.substring('intent://'.length)}';
        } else if (mainPart.startsWith('intent:')) {
          return '$scheme:${mainPart.substring('intent:'.length)}';
        }
      }
    } catch (e) {
      debugPrint('[PddWeb] parseIntentUrl error: $e');
    }
    return null;
  }

  @override
  ConsumerState<PddWebScreen> createState() => _PddWebScreenState();
}

class _PddWebScreenState extends ConsumerState<PddWebScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final WebViewController _controller;
  late final AnimationController _syncSpinController;

  int _loadingProgress = 0;
  bool _isSyncing = false;
  String _pageTitle = '拼多多';
  Timer? _debounceSyncTimer;

  // 外部支付跳转与返回闭环状态
  String? _pendingPaymentRedirectUrl;
  String? _lastWxPayRefererUrl;
  bool _isWaitingPaymentReturn = false;
  String _currentPaymentName = '支付';

  static const String _defaultHomeUrl = 'https://mobile.yangkeduo.com/';
  static const String _ordersUrl = 'https://mobile.yangkeduo.com/orders.html?tab=0';
  static const String _personalUrl = 'https://mobile.yangkeduo.com/personal.html';

  static const List<String> _cookieHosts = [
    'https://mobile.yangkeduo.com',
    'https://yangkeduo.com',
    'https://mobile.pinduoduo.com',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncSpinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _loadingProgress = progress);
            if (progress > 35) {
              _injectCleanUiScript();
            }
          },
          onPageStarted: (url) {
            _updateTitleFromUrl(url);
            _injectCleanUiScript();
          },
          onPageFinished: (url) async {
            if (mounted) {
              setState(() => _loadingProgress = 100);
            }
            await _injectCleanUiScript();
            await _onPageFinished(url);
          },
          onNavigationRequest: (request) {
            final url = request.url;
            final lower = url.toLowerCase();

            // 1. 拦截唤起拼多多官方 App（防止跳出和互踢）
            if (lower.startsWith('pinduoduo://') || lower.startsWith('pddopen://')) {
              debugPrint('[PddWeb] Prevent external pdd scheme: $url');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已为您停留在内置网页版，免受官方 App 打扰与互踢'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
              return NavigationDecision.prevent;
            }

            // 2. 微信 H5 支付（wx.tenpay.com）拦截与 Referer 补全
            if (lower.contains('wx.tenpay.com')) {
              final uri = Uri.tryParse(url);
              final redirectUrl = uri?.queryParameters['redirect_url'];
              if (redirectUrl != null && redirectUrl.isNotEmpty) {
                // queryParameters 已完成一次百分号解码，无需再 decodeFull（重复解码遇到字面 % 会抛异常）
                _pendingPaymentRedirectUrl = redirectUrl;
                debugPrint('[PddWeb] Recorded wxpay redirect_url: $_pendingPaymentRedirectUrl');
              }

              // 若尚未注入 Referer，拦截并带有合法 Referer 重新加载
              if (_lastWxPayRefererUrl != url) {
                _lastWxPayRefererUrl = url;
                debugPrint('[PddWeb] Reloading wx.tenpay with Referer header');
                _controller.loadRequest(
                  Uri.parse(url),
                  headers: const {
                    'Referer': 'https://mobile.yangkeduo.com/',
                  },
                );
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            }

            // 3. 支付宝网页收银台记录返回地址
            if (lower.contains('alipay.com')) {
              final uri = Uri.tryParse(url);
              final returnUrl = uri?.queryParameters['return_url'];
              if (returnUrl != null && returnUrl.isNotEmpty) {
                _pendingPaymentRedirectUrl = returnUrl;
                debugPrint('[PddWeb] Recorded alipay return_url: $_pendingPaymentRedirectUrl');
              }
            }

            // 4. Android Intent 协议识别（解析出真实的 alipays:// 或 weixin://）
            if (lower.startsWith('intent://') || lower.startsWith('intent:')) {
              final parsed = PddWebScreen.parseIntentUrl(url);
              if (parsed != null && parsed.isNotEmpty) {
                debugPrint('[PddWeb] Resolved intent to external scheme: $parsed');
                final isAlipay = parsed.toLowerCase().startsWith('alipay');
                final isWechat = parsed.toLowerCase().startsWith('weixin');
                _launchExternalPay(
                  parsed,
                  paymentName: isAlipay ? '支付宝' : (isWechat ? '微信支付' : '支付软件'),
                );
                return NavigationDecision.prevent;
              }
            }

            // 5. 外部原生支付协议拦截（微信、支付宝、云闪付）
            if (lower.startsWith('weixin://')) {
              debugPrint('[PddWeb] Launch external wechat pay: $url');
              _launchExternalPay(url, paymentName: '微信支付');
              return NavigationDecision.prevent;
            }

            if (lower.startsWith('alipays://') ||
                lower.startsWith('alipay://') ||
                lower.startsWith('alipayqr://')) {
              debugPrint('[PddWeb] Launch external alipay: $url');
              _launchExternalPay(url, paymentName: '支付宝');
              return NavigationDecision.prevent;
            }

            if (lower.startsWith('upowp://')) {
              debugPrint('[PddWeb] Launch external upowp: $url');
              _launchExternalPay(url, paymentName: '云闪付');
              return NavigationDecision.prevent;
            }

            // 6. 拨打电话
            if (lower.startsWith('tel:')) {
              _launchExternal(url);
              return NavigationDecision.prevent;
            }

            // 7. 其他未知非 HTTP 协议阻断
            if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
              debugPrint('[PddWeb] Prevent unknown scheme: $url');
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            debugPrint('[PddWeb Error] code: ${error.errorCode}, desc: ${error.description}');
          },
        ),
      );

    _initAndLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceSyncTimer?.cancel();
    _syncSpinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isWaitingPaymentReturn) {
      _isWaitingPaymentReturn = false;
      _handlePaymentReturn();
    }
  }

  void _updateTitleFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('orders.html')) {
      _pageTitle = '我的订单';
    } else if (lower.contains('personal.html')) {
      _pageTitle = '个人中心';
    } else if (lower.contains('goods.html')) {
      _pageTitle = '商品详情';
    } else if (lower.contains('order.html') || lower.contains('express')) {
      _pageTitle = '物流追踪';
    } else {
      _pageTitle = '拼多多';
    }
    if (mounted) setState(() {});
  }

  /// 初始化并注入已保存的会话 Cookie
  Future<void> _initAndLoad() async {
    final saved = PlatformAuthStore().getCookies('pdd');
    if (saved != null && saved.trim().isNotEmpty) {
      final hosts = _cookieHosts.map((e) => Uri.parse(e).host).toSet();
      // 原生注入，保留 HttpOnly/Secure，避免会话令牌被页面脚本读取
      await injectCookieString(cookies: saved, domains: hosts.toList());
      debugPrint('[PddWeb] Injected saved cookies for PDD');
    }

    final targetUrl = widget.initialUrl ?? _defaultHomeUrl;
    await _controller.loadRequest(Uri.parse(targetUrl));
  }

  /// 注入样式与DOM监听器，自动移除「在App打开」、「下载App」等营销浮标
  Future<void> _injectCleanUiScript() async {
    try {
      await _controller.runJavaScript('''
(function() {
  try {
    var styleId = '__pdd_clean_ui_style';
    if (!document.getElementById(styleId)) {
      var style = document.createElement('style');
      style.id = styleId;
      style.textContent = [
        '[class*="open-app"]',
        '[class*="wake-app"]',
        '[class*="app-wake"]',
        '[class*="download-app"]',
        '[class*="app-download"]',
        '[class*="btn-open"]',
        '[class*="btn-app"]',
        '[class*="top-bar-download"]',
        '[class*="bottom-bar-download"]',
        '[id*="open-app"]',
        '[id*="wake-app"]',
        'div[class*="downloadBar"]',
        'div[class*="openApp"]'
      ].join(',') + ' { display: none !important; opacity: 0 !important; visibility: hidden !important; pointer-events: none !important; width: 0 !important; height: 0 !important; }';
      (document.head || document.documentElement).appendChild(style);
    }

    function removeAppBadges() {
      try {
        var all = document.querySelectorAll('div, span, a, p, button');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          var text = (el.innerText || el.textContent || '').trim();
          if (text.indexOf('在App打开') !== -1 ||
              text.indexOf('在APP打开') !== -1 ||
              text.indexOf('在app打开') !== -1 ||
              text.indexOf('App内打开') !== -1 ||
              text.indexOf('APP内打开') !== -1 ||
              (text.indexOf('打开App') !== -1 && text.length <= 10) ||
              (text.indexOf('打开APP') !== -1 && text.length <= 10)) {
            if (text.length <= 20) {
              var target = el;
              var cur = el;
              for (var d = 0; d < 4; d++) {
                if (cur && cur.parentElement && cur.parentElement !== document.body && cur.parentElement !== document.documentElement) {
                  var comp = window.getComputedStyle(cur);
                  if (comp.position === 'fixed' || comp.position === 'absolute') {
                    target = cur;
                    break;
                  }
                  cur = cur.parentElement;
                }
              }
              target.style.setProperty('display', 'none', 'important');
              target.style.setProperty('visibility', 'hidden', 'important');
              target.style.setProperty('pointer-events', 'none', 'important');
              target.style.setProperty('opacity', '0', 'important');
              target.style.setProperty('width', '0px', 'important');
              target.style.setProperty('height', '0px', 'important');
            }
          }
        }
      } catch(e) {}
    }

    removeAppBadges();

    if (!window.__pddCleanObserver) {
      var obs = new MutationObserver(function() {
        removeAppBadges();
      });
      obs.observe(document.documentElement || document.body, {
        childList: true,
        subtree: true
      });
      window.__pddCleanObserver = obs;
    }
  } catch(e) {}
})();
''');
    } catch (_) {}
  }

  Future<void> _onPageFinished(String url) async {
    // 1. 尝试获取真实页面 Title
    try {
      final title = await _controller.getTitle();
      if (title != null && title.trim().isNotEmpty && !title.contains('yangkeduo')) {
        if (mounted) setState(() => _pageTitle = title);
      }
    } catch (_) {}

    // 2. 检查并持久化登录凭据
    await _collectAndSaveCookies();

    // 3. 智能嗅探：若当前进入了具体订单或物流追踪页，延迟等待 DOM 渲染后自动捕获最新状态与取件码
    final lower = url.toLowerCase();
    if (lower.contains('order.html') || lower.contains('express')) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _sniffCurrentPageLogistics();
      });
    }

    // 4. 当用户浏览到订单中心时，防抖触发一次自动静默物流同步
    if (lower.contains('orders.html')) {
      _debounceSyncTimer?.cancel();
      _debounceSyncTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) _syncLogistics(silent: true);
      });
    }
  }

  /// 智能嗅探当前打开的物流页面，立即提取并回传最新包裹与取件码
  Future<void> _sniffCurrentPageLogistics() async {
    try {
      final docText = await _controller.runJavaScriptReturningResult('''
(function(){
  try {
    var btns = document.querySelectorAll('div,span,a,button,p');
    for (var i = 0; i < btns.length; i++) {
      var t = (btns[i].innerText || '').trim();
      if (t === '展开' || t.indexOf('展开更多') !== -1 || t.indexOf('查看更多物流') !== -1 || t.indexOf('全部物流') !== -1) {
        btns[i].click();
      }
    }
  } catch(e) {}
  return document.body ? document.body.innerText.slice(0, 50000) : '';
})()
''');
      var text = docText.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        try {
          text = jsonDecode(text) as String;
        } catch (_) {
          text = text.substring(1, text.length - 1);
        }
      }
      text = text.replaceAll('\\n', '\n');
      if (text.length < 50) return;

      final currentUrl = await _controller.currentUrl() ?? '';
      final uri = Uri.tryParse(currentUrl);
      final orderSn = uri?.queryParameters['order_sn'] ?? '';

      // 没有订单号锚点（例如停留在订单列表页）时，页面上的运单号/取件码未必属于同一单，
      // 直接跳过嗅探，避免把 A 单的取件码与状态贴到 B 单上。
      if (orderSn.isEmpty) return;

      final detail = PddH5Connector.parseLogisticsText(text, orderSn: orderSn);
      if (detail != null) {
        final trackingNumber = detail.trackingNo.isNotEmpty ? detail.trackingNo : orderSn;
        final id = 'PDD_$orderSn';

        var goodsName = '拼多多包裹';
        try {
          final gTitle = await _controller.runJavaScriptReturningResult(
            "(function(){ var el = document.querySelector('[class*=\"goods-name\"], [class*=\"goodsName\"], [class*=\"goods_name\"], [class*=\"goods-title\"], [class*=\"title\"]'); return el ? el.innerText : ''; })()",
          );
          var gt = gTitle.toString().replaceAll('"', '').trim();
          if (gt.isNotEmpty && gt.length >= 2) goodsName = gt;
        } catch (_) {}

        if (goodsName == '拼多多包裹') {
          // 物流/取件说明文本不能当商品名：这类行常含「取件」「出示」「单号」「驿站」等词
          const logisticsKeywords = [
            '取件', '出示', '单号', '提货', '驿站', '自提', '代收', '快递员', '派件', '派送',
            '运输', '签收', '揽收', '转运', '网点', '出库', '发货', '收货地址', '隐私号',
            '订单编号', '预计', '送达', '物流', '包裹已', '快件',
          ];
          for (final line in text.split('\n')) {
            final l = line.trim();
            if (l.length < 8 || l.length > 60) continue;
            if (logisticsKeywords.any(l.contains)) continue;
            if (l.contains('订单编号') ||
                l.contains('收货地址') ||
                l.contains('待发货') ||
                l.contains('拼单成功') ||
                l.contains('实付') ||
                l.contains('退款') ||
                l.contains('免运费') ||
                l.contains('更多订单信息') ||
                l.contains('发生交易') ||
                l.contains('客服') ||
                l.contains('联系商家')) {
              continue;
            }
            if (l.contains('【') || l.contains('包') || l.contains('盒') || l.contains('件') || l.length >= 14) {
              goodsName = l;
              break;
            }
          }
        }

        var goodsPic = '';
        try {
          final gImg = await _controller.runJavaScriptReturningResult(
            "(function(){ var el = document.querySelector('img[src*=\"pddpic\"], img[src*=\"yangkeduo\"], [class*=\"goods\"] img'); return el ? el.src : ''; })()",
          );
          var gi = gImg.toString().replaceAll('"', '').trim();
          if (gi.startsWith('http')) goodsPic = gi;
        } catch (_) {}

        final pkg = Package(
          id: id,
          trackingNumber: trackingNumber,
          courier: detail.courier,
          goodsName: goodsName,
          goodsImageUrl: goodsPic.isNotEmpty ? goodsPic : null,
          stationName: detail.status == PackageStatus.pendingShipment
              ? null
              : (detail.stationName.isNotEmpty ? detail.stationName : null),
          pickupCode: detail.pickupCode,
          location: detail.address,
          description: detail.latestText,
          platform: 'pdd',
          urgency: detail.status.isArrived ? UrgencyLevel.urgent : UrgencyLevel.normal,
          status: detail.status,
          addedAt: DateTime.now(),
          rawTimelineJson: detail.rawTimelineJson,
        );

        ref.read(packageListProvider.notifier).addPackage(pkg);
        debugPrint('[PddWeb] Sniffed package from active page: id=$id courier=${detail.courier.displayName} '
            'tracking=$trackingNumber status=${detail.status.label} code=${detail.pickupCode}');
      }
    } catch (e) {
      debugPrint('[PddWeb] Sniff current page error: $e');
    }
  }

  /// 收集 Cookie 并落盘
  Future<void> _collectAndSaveCookies() async {
    try {
      final cookieMap = <String, String>{};
      final cookieManager = WebViewCookieManager();

      for (final host in _cookieHosts) {
        try {
          final cookies = await cookieManager.getCookies(domain: Uri.parse(host));
          for (final c in cookies) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) {
              cookieMap[c.name] = c.value;
            }
          }
        } catch (_) {}
      }

      // 仅当当前页面属于拼多多可信域时才采集页面级 Cookie，
      // 否则会把支付中转页（微信/支付宝）的第三方会话混入拼多多凭据存储。
      var currentHost = '';
      try {
        final h = await _controller.runJavaScriptReturningResult('location.host || ""');
        currentHost = h.toString().replaceAll('"', '').trim();
      } catch (_) {}
      final trustedPage = _isTrustedPddHost(currentHost);
      if (!trustedPage) {
        debugPrint('[PddWeb] skip page-level cookie: host "$currentHost" not trusted');
        return;
      }

      try {
        final docCookie = await _controller.runJavaScriptReturningResult('document.cookie || ""');
        var raw = docCookie.toString();
        if (raw.startsWith('"') && raw.endsWith('"')) {
          raw = raw.substring(1, raw.length - 1);
        }
        for (final part in raw.split(';')) {
          final idx = part.indexOf('=');
          if (idx <= 0) continue;
          final name = part.substring(0, idx).trim();
          final value = part.substring(idx + 1).trim();
          if (name.isNotEmpty && value.isNotEmpty && !cookieMap.containsKey(name)) {
            cookieMap[name] = value;
          }
        }
      } catch (_) {}

      final merged = cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
      const markers = ['PDDAccessToken', 'pdd_user_id', 'pdduid', 'AccessToken'];
      final hasToken = markers.any(merged.contains);

      if (hasToken) {
        await PlatformAuthStore().saveCookies('pdd', merged);
        final currentHref = await _controller.runJavaScriptReturningResult('location.href');
        var hrefStr = currentHref.toString();
        if (hrefStr.startsWith('"') && hrefStr.endsWith('"')) {
          hrefStr = hrefStr.substring(1, hrefStr.length - 1);
        }
        if (hrefStr.startsWith('http') && !hrefStr.contains('login')) {
          await PlatformAuthStore().saveEntryUrl('pdd', hrefStr);
        }
      }
    } catch (e) {
      debugPrint('[PddWeb] Save cookies error: $e');
    }
  }

  /// 触发物流信息同步
  Future<void> _syncLogistics({bool silent = false}) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    _syncSpinController.repeat();

    try {
      // 1. 若当前用户正打开某一具体订单物流，优先嗅探本页最新状态
      await _sniffCurrentPageLogistics();

      // 2. 确保最新凭据已保存
      await _collectAndSaveCookies();

      // 3. 调度连接器全量同步
      final manager = ref.read(connectorManagerProvider);
      final count = await manager.syncAll();

      if (!mounted) return;
      HapticFeedback.lightImpact();

      if (!silent) {
        final issue = manager.lastIssue;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              issue ?? (count > 0 ? '同步成功：已聚合 $count 件包裹与取件码' : '拼多多包裹状态已是最新'),
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('[PddWeb] Sync error: $e');
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('同步异常: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        _syncSpinController.stop();
        setState(() => _isSyncing = false);
      }
    }
  }

  /// 允许唤起外部应用的支付相关 scheme 白名单
  static const Set<String> _allowedPaySchemes = {
    'alipays',
    'alipay',
    'weixin',
    'uppay',
    'upwrp',
    'unionpay',
  };

  /// 拼多多可信域判定（用于页面级凭据采集与回跳地址校验）
  static bool _isTrustedPddHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty) return false;
    return h == 'yangkeduo.com' ||
        h.endsWith('.yangkeduo.com') ||
        h == 'pinduoduo.com' ||
        h.endsWith('.pinduoduo.com');
  }

  /// 支付回跳地址必须为 https 且落在拼多多可信域
  static bool _isSafePddRedirect(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    return _isTrustedPddHost(uri.host);
  }

  /// 唤起本地支付软件（微信、支付宝、云闪付）并标记等待返回
  Future<void> _launchExternalPay(String url, {required String paymentName}) async {
    try {
      final uri = Uri.parse(url);
      // 仅允许白名单内的支付 scheme，防止恶意页面通过构造 URL 唤起任意应用深链
      if (!_allowedPaySchemes.contains(uri.scheme.toLowerCase())) {
        debugPrint('[PddWeb] blocked external launch for scheme: ${uri.scheme}');
        return;
      }
      _isWaitingPaymentReturn = true;
      _currentPaymentName = paymentName;

      bool launched = false;
      try {
        launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        debugPrint('[PddWeb] launch externalApplication error: $e, retry platformDefault');
        try {
          launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
        } catch (_) {}
      }

      if (!launched && mounted) {
        _isWaitingPaymentReturn = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('未检测到本地已安装的$paymentName，请确认已安装或在页面中重新选择其他支付方式'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        debugPrint('[PddWeb] Successfully launched $paymentName: $url');
      }
    } catch (e) {
      _isWaitingPaymentReturn = false;
      debugPrint('[PddWeb] launchExternalPay error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('唤起$paymentName失败，请稍后重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// 处理从微信、支付宝等支付应用返回后的界面切换与物流同步
  Future<void> _handlePaymentReturn() async {
    if (!mounted) return;
    HapticFeedback.lightImpact();

    // 1. 如果页面仍停留在微信或支付宝的中间过渡页，将其自动导航至订单中心或回调地址
    try {
      final currentUrl = await _controller.currentUrl();
      if (currentUrl != null) {
        final lower = currentUrl.toLowerCase();
        if (lower.contains('wx.tenpay.com') ||
            lower.contains('mclient.alipay.com') ||
            lower.contains('cashier')) {
          // 回跳地址必须落在拼多多可信域内，避免页面用 javascript:/外部站点做注入或钓鱼跳转
          final candidate = _pendingPaymentRedirectUrl;
          final target = (candidate != null && _isSafePddRedirect(candidate)) ? candidate : _ordersUrl;
          debugPrint('[PddWeb] Navigating away from transit page to: $target');
          await _controller.loadRequest(Uri.parse(target));
        }
      }
    } catch (_) {}

    if (!mounted) return;

    // 2. 弹出非阻塞的支付结果操作条，让用户一键完成并立即同步物流
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已从$_currentPaymentName返回，是否已完成支付？'),
        duration: const Duration(seconds: 8),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '已完成支付',
          textColor: const Color(0xFFFFD60A),
          onPressed: () async {
            await _controller.loadRequest(Uri.parse(_ordersUrl));
            await _syncLogistics(silent: false);
          },
        ),
      ),
    );
  }

  Future<void> _launchExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      // 与支付唤起共用白名单，避免任意深链被页面触发
      if (uri.scheme != 'https' && uri.scheme != 'http' &&
          !_allowedPaySchemes.contains(uri.scheme.toLowerCase())) {
        debugPrint('[PddWeb] blocked launchExternal for scheme: ${uri.scheme}');
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[PddWeb] launchExternal error: $e');
    }
  }

  Future<bool> _handleBackPress() async {
    final canGoBack = await _controller.canGoBack();
    if (canGoBack) {
      await _controller.goBack();
      return false;
    }
    // 退出前最后落盘一次会话与嗅探
    await _sniffCurrentPageLogistics();
    await _collectAndSaveCookies();
    return true;
  }

  /// 直接关闭并返回取件助手首页
  Future<void> _closeToHome() async {
    HapticFeedback.lightImpact();
    await _sniffCurrentPageLogistics();
    await _collectAndSaveCookies();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    const brandRed = Color(0xFFE02E24);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _handleBackPress();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1C1C1E),
          elevation: 0.5,
          leading: IconButton(
            icon: const Icon(Icons.close_rounded, size: 22),
            tooltip: '返回软件首页',
            onPressed: _closeToHome,
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: brandRed,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.local_fire_department_rounded,
                  color: Colors.white,
                  size: 15,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _pageTitle,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Text(
                      '免App · 物流自动同步',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFF8E8E93),
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            // 快捷进入“我的订单”
            IconButton(
              icon: const Icon(Icons.receipt_long_rounded, size: 20),
              tooltip: '我的订单',
              onPressed: () {
                HapticFeedback.lightImpact();
                _controller.loadRequest(Uri.parse(_ordersUrl));
              },
            ),
            // 同步物流按钮
            IconButton(
              icon: RotationTransition(
                turns: _syncSpinController,
                child: Icon(
                  Icons.sync_rounded,
                  size: 20,
                  color: _isSyncing ? brandRed : const Color(0xFF1C1C1E),
                ),
              ),
              tooltip: '同步物流到待取件',
              onPressed: _isSyncing ? null : () => _syncLogistics(silent: false),
            ),
            // 更多功能菜单
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onSelected: (value) async {
                HapticFeedback.lightImpact();
                switch (value) {
                  case 'exit_home':
                    await _closeToHome();
                    break;
                  case 'home':
                    _controller.loadRequest(Uri.parse(_defaultHomeUrl));
                    break;
                  case 'personal':
                    _controller.loadRequest(Uri.parse(_personalUrl));
                    break;
                  case 'reload':
                    _controller.reload();
                    break;
                  case 'clear':
                    final messenger = ScaffoldMessenger.of(context);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('退出拼多多登录'),
                        content: const Text('将清除本地保存的拼多多 Cookie 凭据。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('确定退出', style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await PlatformAuthStore().unbind('pdd');
                      await WebViewCookieManager().clearCookies();
                      await _controller.loadRequest(Uri.parse(_defaultHomeUrl));
                      if (!mounted) return;
                      messenger.showSnackBar(
                        const SnackBar(content: Text('已清除拼多多本地登录状态')),
                      );
                    }
                    break;
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'exit_home',
                  child: Row(
                    children: [
                      Icon(Icons.arrow_back_rounded, size: 18, color: Color(0xFF007AFF)),
                      SizedBox(width: 8),
                      Text(
                        '返回软件首页',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF007AFF),
                        ),
                      ),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'home',
                  child: Row(
                    children: [
                      Icon(Icons.home_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('拼多多首页', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'personal',
                  child: Row(
                    children: [
                      Icon(Icons.person_outline_rounded, size: 18),
                      SizedBox(width: 8),
                      Text('个人中心', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'reload',
                  child: Row(
                    children: [
                      Icon(Icons.refresh_rounded, size: 18),
                      SizedBox(width: 8),
                      Text('刷新页面', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'clear',
                  child: Row(
                    children: [
                      Icon(Icons.logout_rounded, size: 18, color: Colors.red),
                      SizedBox(width: 8),
                      Text('清除登录', style: TextStyle(fontSize: 14, color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loadingProgress < 100)
              LinearProgressIndicator(
                value: _loadingProgress / 100.0,
                backgroundColor: Colors.transparent,
                color: brandRed,
                minHeight: 2.5,
              ),
            Expanded(
              child: WebViewWidget(controller: _controller),
            ),
          ],
        ),
      ),
    );
  }
}
