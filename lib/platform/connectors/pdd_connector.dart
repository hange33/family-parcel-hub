/// 拼多多真实连接器
///
/// 两阶段同步：
/// 1) 订单列表：拼多多 proxy 接口要求 anti_content 动态签名，纯 HTTP 会被风控（424）。
///    因此在本地 WebView 页面上下文内 fetch，由页面 SDK 完成签名，经 JavaScript Channel 回传。
/// 2) 取件码补全：对「已到驿站/待取件」的订单，加载订单详情页并进入物流页，
///    读取页面文本抽取取件码与驿站信息。
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../../core/models/package.dart';
import '../../core/models/package_status.dart';
import '../../core/engine/logistics_status_engine.dart';
import '../../core/engine/timeline_merge.dart';
import '../../core/parser/trace_time.dart';
import '../../core/sanitizer/goods_name_cleaner.dart';
import '../storage/platform_auth_store.dart';
import '../webview/platform_cookie.dart';
import 'pdd_trace_parser.dart';
import 'platform_connector.dart';
import 'concurrent_limiter.dart';

/// 保活探活结果
///
/// 只表达两种可判定的结局；「无法判定」（正忙 / 网络异常）由
/// [PddH5Connector.keepAliveProbe] 返回 null 表达。
class PddKeepAliveProbe {
  /// 登录态是否仍然有效
  final bool healthy;

  const PddKeepAliveProbe.healthy() : healthy = true;

  const PddKeepAliveProbe.expired() : healthy = false;
}

class PddH5Connector implements PlatformConnector {
  final PlatformAuthStore _authStore;
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  PddH5Connector({PlatformAuthStore? authStore})
      : _authStore = authStore ?? PlatformAuthStore();

  @override
  String get platformId => 'pdd';

  @override
  String get displayName => '拼多多';

  @override
  String get brandColorHex => '#E02E24';

  @override
  Future<bool> isAuthenticated() async => _authStore.isBound('pdd');

  @override
  Future<void> cancelSync() async {}

  WebViewController? _controller;
  Completer<String>? _bridgeCompleter;
  String? _lastIssue;

  /// 同步与保活探活共用同一个 WebView，用互斥位串行化，避免两个 loadRequest 互相打断
  bool _busy = false;

  /// 物流时间线缓存：orderSn -> (抓取时的列表最新轨迹, 时间线 JSON)
  /// 列表接口返回的最新轨迹未发生变化时，说明包裹没有新动态，直接复用缓存，无需再次深挖详情页。
  final Map<String, _TimelineCache> _timelineCache = {};
  int _cacheHits = 0;

  /// 上一次已写入 WebView 的 Cookie 串，用于避免每次同步重复写入
  String? _lastInjectedCookies;

  /// 是否已打印过订单对象的字段清单（用于定位官方二级状态字段）
  int _listKeysDumpedCount = 0;

  @override
  String? get lastIssue => _lastIssue;

  /// 用户重新授权后清理上一次的失效提示
  void clearLastIssue() {
    _lastIssue = null;
  }

  /// 复用同一个 WebView 实例，避免每次同步重建带来的额外开销
  Future<void> _ensureController() async {
    if (_controller != null) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      ..addJavaScriptChannel(
        'PddBridge',
        onMessageReceived: (JavaScriptMessage message) {
          final m = message.message;
          if (m.startsWith('{"type":"LOGISTICS_API"')) {
            _handleCapturedLogisticsApi(m);
            return;
          }
          debugPrint('[PDD] Bridge msg len=${m.length}');
          final c = _bridgeCompleter;
          if (c != null && !c.isCompleted) c.complete(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final url = request.url.toLowerCase();
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            debugPrint('[PDD] WebResourceError: ${error.description}');
          },
        ),
      );

    _controller = controller;

    // Android 原生 document-start JavaScript 注入，直接挂载 XHR/fetch Hook 绕开 HTTP 缓存
    if (defaultTargetPlatform == TargetPlatform.android &&
        controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      final id = androidController.webViewIdentifier;
      await _installDocumentStartHook(id);
    }
  }

  static const _hookChannel = MethodChannel('com.example.pickup_app/webview_hook');
  final Map<String, String> _capturedLogisticsJsons = {};

  Future<void> _installDocumentStartHook(int identifier) async {
    try {
      const hookScript = '''
(function() {
  if (window.__pdd_logistics_hooked) return;
  window.__pdd_logistics_hooked = true;

  function isLogisticsUrl(u) {
    if (!u) return false;
    var s = String(u).toLowerCase();
    var kw = ['express', 'logistics', 'tracking', 'trace', 'shipment', 'shipping_detail'];
    return kw.some(function(k) { return s.indexOf(k) !== -1; });
  }

  function pushWindowName(url, body) {
    try {
      var arr = [];
      if (window.name && window.name.charAt(0) === '[') {
        try { arr = JSON.parse(window.name); } catch(e) { arr = []; }
      }
      arr.push({ u: String(url || '').slice(0, 300), b: String(body || '') });
      if (arr.length > 200) arr = arr.slice(arr.length - 200);
      window.name = JSON.stringify(arr);
    } catch(e) {}
  }

  function reportLogistics(url, body) {
    try {
      if (!body || body.length < 30) return;
      if (body.indexOf('orders') !== -1 && body.indexOf('aristotle') !== -1) return;
      pushWindowName(url, body);
      PddBridge.postMessage(JSON.stringify({
        type: 'LOGISTICS_API',
        url: String(url),
        body: String(body)
      }));
    } catch(e) {}
  }

  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function(input, init) {
      var url = (typeof input === 'string') ? input : (input ? input.url : '');
      if (isLogisticsUrl(url) && init) {
        try { init.cache = 'no-store'; } catch(e) {}
      }
      return origFetch.apply(this, arguments).then(function(res) {
        if (isLogisticsUrl(url)) {
          try {
            var clone = res.clone();
            clone.text().then(function(t) { reportLogistics(url, t); });
          } catch(e) {}
        }
        return res;
      });
    };
  }

  if (window.XMLHttpRequest) {
    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
      this.__pdd_req_url = url;
      return origOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function(body) {
      var self = this;
      if (isLogisticsUrl(this.__pdd_req_url)) {
        try {
          this.setRequestHeader('Cache-Control', 'no-cache');
          this.setRequestHeader('Pragma', 'no-cache');
        } catch(e) {}
        this.addEventListener('load', function() {
          try { reportLogistics(self.__pdd_req_url, self.responseText); } catch(e) {}
        });
      }
      return origSend.apply(this, arguments);
    };
  }
})();
''';

      final res = await _hookChannel.invokeMethod<bool>('installDocumentStartHook', {
        'identifier': identifier,
        'script': hookScript,
        'origins': ['https://mobile.yangkeduo.com', 'https://yangkeduo.com', 'https://mobile.pinduoduo.com'],
      });
      debugPrint('[PDD] installDocumentStartHook result: $res on webview $identifier');
    } catch (e) {
      debugPrint('[PDD] installDocumentStartHook error: $e');
    }
  }

  /// 记录抓取到的官方物流接口响应
  void _handleCapturedLogisticsApi(String rawMsg) {
    try {
      final data = jsonDecode(rawMsg) as Map<String, dynamic>;
      final url = data['url']?.toString() ?? '';
      final body = data['body']?.toString() ?? '';
      final snMatch = RegExp(r'order_sn=([^&]+)').firstMatch(url);
      if (snMatch != null) {
        _capturedLogisticsJsons[snMatch.group(1)!] = body;
      }
    } catch (e) {
      debugPrint('[PDD] handle captured api error: $e');
    }
  }

  @override
  Stream<Package> streamSync() async* {
    // 保活探活与同步共用同一个 WebView，必须串行，否则两个 loadRequest 会互相打断
    if (_busy) {
      debugPrint('[PDD] busy, skip sync');
      return;
    }

    final cookies = _authStore.getCookies('pdd');
    if (cookies == null || cookies.trim().isEmpty) {
      debugPrint('[PDD] No cookies, skip');
      return;
    }

    _busy = true;
    try {
      debugPrint('[PDD] Cookie len: ${cookies.length}');
      _lastIssue = null;
      await _injectCookies(cookies);
      await _ensureController();

      try {
        // ── 阶段 1：订单列表 ─────────────────────────────────
        final listJson = await _fetchOrderList();
        if (listJson == null || listJson.isEmpty) {
          debugPrint('[PDD] Order list empty');
          return;
        }

        final orders = _extractOrders(listJson);
        debugPrint('[PDD] Parsed ${orders.length} orders');
        if (orders.isEmpty) return;
        // 订单列表拉取成功 → 登录态健康，清除此前的失效标记
        await _authStore.setExpired('pdd', false);

        final pendingCodes = <String, _PddOrder>{}; // orderSn -> order（优先深挖时间轴）
        _cacheHits = 0;

        for (final o in orders) {
          final parsed = _parseOrder(o);
          if (parsed == null) continue;
          if (parsed.isFiltered) continue;

          final isCompleted = parsed.package.status == PackageStatus.pickedUp ||
              parsed.package.status == PackageStatus.archived ||
              parsed.package.status == PackageStatus.rejected;

          // 【新模式核心约束】：所有已经完成的都不同步！
          if (isCompleted) {
            debugPrint('[PDD NewMode] 已经完成，跳过同步: ${parsed.package.id} (${parsed.package.status.label})');
            continue;
          }

          final orderSn = parsed.package.id.replaceFirst('PDD_', '');
          final listTrace = parsed.package.description;

          // 仅在动态 TTL 保护期内且时间轴节点完整、轨迹未变时复用缓存
          final cached = _timelineCache[orderSn];
          if (cached != null &&
              cached.timelineJson != null &&
              cached.isFresh() &&
              cached.nodeCount >= 3 &&
              listTrace.isNotEmpty &&
              cached.latestTrace == listTrace) {
            _cacheHits++;
            yield parsed.package.copyWith(
              description: cached.latestText.isNotEmpty ? cached.latestText : parsed.package.description,
              rawTimelineJson: cached.timelineJson,
              status: cached.status,
            );
            continue;
          }

          // 优先同步时间轴：在运（在途/派件）、已购买（待发货）、到货（待取件）
          pendingCodes[orderSn] = parsed.orderMeta;
        }

        debugPrint('[PDD NewMode] 活跃在运/已购/到货包裹: ${pendingCodes.length}单需深挖时间轴, 缓存复用: $_cacheHits单');

        yield* _enrichPending(pendingCodes);
      } finally {
        // 无论本次同步成功、失败还是中断，都尝试把刷新后的 Cookie 回写（仅当登录态健康）
        await _persistCookiesIfHealthy(cookies);
      }
    } finally {
      _busy = false;
    }
  }

  /// 复用常驻 WebView 探活一次登录态（仅前台可用）
  ///
  /// 返回 null 表示「本轮无法探活」——连接器正忙、控制器不可用或网络异常，
  /// 调用方必须视作「跳过」而非「登录失效」，避免误判。
  ///
  /// 后台 isolate 不持有本对象，因此进程外不会（也无法）走这条路径：
  /// 拼多多 proxy 接口要求 `anti_content` 动态签名，纯 HTTP 会被风控（424）。
  Future<PddKeepAliveProbe?> keepAliveProbe() async {
    if (_busy) {
      debugPrint('[PDD] keepAliveProbe skipped: busy');
      return null;
    }

    final cookies = _authStore.getCookies('pdd');
    if (cookies == null || cookies.trim().isEmpty) return null;

    _busy = true;
    try {
      await _injectCookies(cookies);
      await _ensureController();
      if (_controller == null) return null;

      _lastIssue = null;
      final listJson = await _fetchOrderList();

      // _fetchOrderList 命中登录页/424 时会置 _lastIssue 并落盘失效标记
      if (_lastIssue != null) {
        debugPrint('[PDD] keepAliveProbe: login expired');
        return const PddKeepAliveProbe.expired();
      }
      if (listJson != null && listJson.isNotEmpty) {
        debugPrint('[PDD] keepAliveProbe: healthy');
        return const PddKeepAliveProbe.healthy();
      }
      debugPrint('[PDD] keepAliveProbe: inconclusive (no data)');
      return null;
    } catch (e) {
      debugPrint('[PDD] keepAliveProbe error: $e');
      return null;
    } finally {
      _busy = false;
    }
  }

  Stream<Package> _enrichPending(Map<String, _PddOrder> pendingCodes) async* {
    // ── 阶段 2：优先获取时间轴，并由软件引擎推导货物状态、稳定性与同步周期 ──
    try {
      await _controller?.clearCache();
    } catch (_) {}

    // ⚡ 优化：并发拉取订单详情（限制并发数为 3）
    final executor = ThrottledExecutor(
      maxConcurrent: 3,
      minDelay: const Duration(milliseconds: 200),
      maxDelay: const Duration(milliseconds: 400),
    );

    final detailTasks = pendingCodes.entries.map((entry) {
      return () => _fetchOrderDetail(entry.key, base: entry.value.pkg).then((detail) {
        return {'orderSn': entry.key, 'order': entry.value, 'detail': detail};
      });
    }).toList();

    final results = await executor.executeAll(detailTasks);

    for (final result in results) {
      final orderSn = result['orderSn'] as String;
      final orderEntry = result['order'] as _PddOrder;
      final detail = result['detail'] as PddDetailResult?;

      if (detail == null) continue;

      final base = orderEntry.pkg;

      // ── 关键：由软件基于时间轴事件序列推导货物真实状态、时间轴稳定性与下次同步周期 ──
      final events = detail.parsedTimelineNodes;
      final derived = LogisticsStatusEngine.derive(
        events: events,
        isPendingShipment: base.status == PackageStatus.pendingShipment,
        isOrderSigned: detail.status == PackageStatus.pickedUp,
        pickupCode: detail.pickupCode.isNotEmpty ? detail.pickupCode : base.pickupCode,
        stationName: detail.stationName.isNotEmpty ? detail.stationName : (base.stationName ?? ''),
      );

      final derivedStatus = derived.status;
      final syncInterval = derived.recommendedSyncInterval;

      debugPrint('[PDD NewMode] 订单 $orderSn 时间轴推导完成 => '
          '货物状态: 【${derivedStatus.label}】 '
          '稳定性: 【${derived.stabilityName}】 '
          '建议同步间隔: ${syncInterval.inMinutes >= 60 ? "${syncInterval.inHours}小时" : "${syncInterval.inMinutes}分钟"} '
          '时间轴节点数: ${events.length}');

      final effectiveDescription = detail.latestText.isNotEmpty ? detail.latestText : base.description;
      final cachedTimeline = _richerTimeline(detail.rawTimelineJson, base.rawTimelineJson);

      _timelineCache[orderSn] = _TimelineCache(
        base.description,
        cachedTimeline,
        effectiveDescription,
        status: derivedStatus,
        nodeCount: _timelineNodeCount(cachedTimeline),
        recommendedSyncInterval: syncInterval,
      );

      yield base.copyWith(
        courier: detail.courier != CourierType.other ? detail.courier : base.courier,
        trackingNumber: detail.trackingNo.isNotEmpty ? detail.trackingNo : base.trackingNumber,
        pickupCode: detail.pickupCode.isNotEmpty ? detail.pickupCode : base.pickupCode,
        stationName: detail.stationName.isNotEmpty ? detail.stationName : base.stationName,
        location: detail.address.isNotEmpty ? detail.address : base.location,
        description: effectiveDescription,
        status: derivedStatus, // 严格以软件根据时间轴推导出的货物状态为准
        rawTimelineJson: cachedTimeline,
      );
    }
  }

  /// 合并「订单列表官方分类」与「详情页最新轨迹」两侧状态：取生命周期更靠后的阶段，禁止倒退。
  ///
  /// 注意：详情页明确已签收（pickedUp）时必须采信详情，否则取件后卡片会一直停在待取件，
  /// 到件提醒也不会被取消。
  @visibleForTesting
  static PackageStatus mergeStatus(PackageStatus listStatus, PackageStatus detailStatus) {
    return _statusRank(listStatus) > _statusRank(detailStatus) ? listStatus : detailStatus;
  }

  /// 合并两份时间轴节点为无损并集，避免单节点残缺数据覆盖完整轨迹
  static String? _richerTimeline(String? a, String? b) {
    return mergeTimelineJson(b, a);
  }

  /// 时间轴 JSON 的节点数量（解析失败按 0 计）
  static int _timelineNodeCount(String? json) {
    if (json == null || json.isEmpty) return 0;
    try {
      return (jsonDecode(json) as List).length;
    } catch (_) {
      return 0;
    }
  }

  /// 包裹生命周期阶段排序，用于判断哪一侧的状态更靠后
  ///
  /// 已拒收是终结态：即使列表接口仍返回在途文案，也不允许把它拉回在途。
  static int _statusRank(PackageStatus s) {
    switch (s) {
      case PackageStatus.pendingShipment:
        return 0;
      case PackageStatus.transit:
        return 1;
      case PackageStatus.delivering:
        return 2;
      case PackageStatus.arrived:
        return 3;
      case PackageStatus.pickedUp:
        return 4;
      case PackageStatus.archived:
        return 5;
      case PackageStatus.rejected:
        return 6;
    }
  }

  Future<void> _injectCookies(String cookies) async {
    // 会话保持不变时无需重复写入数十条 Cookie，直接跳过以节省每次同步的固定开销
    if (_lastInjectedCookies == cookies) {
      debugPrint('[PDD] cookies unchanged, skip injection');
      return;
    }
    // 原生注入，保留 HttpOnly/Secure，避免把会话令牌降级为页面脚本可读
    await injectCookieString(
      cookies: cookies,
      domains: const ['mobile.yangkeduo.com', 'yangkeduo.com'],
    );
    debugPrint('[PDD] cookies injected');
    _lastInjectedCookies = cookies;
  }

  /// 读取当前页面纯文本（无副作用，便于高频轮询，避免每次轮询都执行 DOM 扫描）
  Future<String> _domText() async {
    final controller = _controller;
    if (controller == null) return '';
    try {
      final result = await controller.runJavaScriptReturningResult(
        "(function(){return document.body ? document.body.innerText.slice(0, 40000) : '';})()",
      );
      var text = result.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        try {
          text = jsonDecode(text) as String;
        } catch (_) {
          text = text.substring(1, text.length - 1);
        }
      }
      return text.replaceAll('\\n', '\n');
    } catch (_) {
      return '';
    }
  }

  /// 展开被折叠的历史物流节点（每页只调用一次，绝不触发底部推荐商品流滚动）
  Future<void> _expandAndScroll() async {
    try {
      await _controller?.runJavaScript('''
(function(){
  try {
    var els = document.querySelectorAll('div,span,a,button,p');
    for (var i = 0; i < els.length; i++) {
      var t = (els[i].innerText || '').trim();
      if (t === '展开' || t === '展开更多' || t.indexOf('展开更多物流') !== -1 ||
          t.indexOf('查看更多物流') !== -1 || t.indexOf('全部物流') !== -1) {
        try { els[i].click(); } catch(e) {}
      }
    }
  } catch(e) {}
})();
''');
    } catch (_) {}
  }

  /// 轮询等待页面与 JS 运行时就绪（document 完成 + fetch 可用），再留一小段 SDK 初始化时间
  Future<void> _awaitPageInteractive() async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    var ready = false;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await _controller?.runJavaScriptReturningResult(
          "(function(){return (document.readyState==='complete' && typeof window.fetch==='function') ? '1' : '0';})()",
        );
        if (r != null && r.toString().contains('1')) {
          ready = true;
          break;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!ready) {
      debugPrint('[PDD] page interactive wait timed out, continue anyway');
    }
    // 站点 SDK 初始化缓冲
    await Future.delayed(const Duration(milliseconds: 150));
  }

  /// 轮询等待点击「查看物流」后跳转的官方物流轨迹页面（页面以时间戳和运输轨迹为主）
  Future<String> _awaitExpressTimelineText({Duration timeout = const Duration(milliseconds: 3200)}) async {
    final deadline = DateTime.now().add(timeout);
    final timeMarker = RegExp(r'\d{4}[-/.]\d{2}[-/.]\d{2}\s+\d{2}:\d{2}');
    var text = '';
    var scrolled = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
      final curText = await _domText();
      if (!scrolled && curText.length >= 80) {
        scrolled = true;
        await _expandAndScroll();
      }
      final tsCount = timeMarker.allMatches(curText).length;
      if (tsCount >= 3 || (curText.length >= 400 && tsCount >= 1)) {
        text = curText;
        break;
      }
      if (curText.length > text.length) {
        text = curText;
      }
    }
    return text;
  }

  /// 点击「查看物流」进入拼多多官方物流轨迹页
  Future<bool> _clickViewLogistics() async {
    try {
      final res = await _controller?.runJavaScriptReturningResult('''
(function(){
  try {
    var els = document.querySelectorAll('div,span,button,a,p');
    var labels = ['查看物流', '查物流', '物流详情', '物流信息', '查看物流信息',
                  '查看全部物流', '物流轨迹', '查看物流轨迹', '包裹跟踪'];
    for (var i = 0; i < els.length; i++) {
      var t = (els[i].innerText || '').trim();
      if (t.length === 0 || t.length > 12) continue;
      for (var j = 0; j < labels.length; j++) {
        if (t === labels[j]) {
          try { els[i].scrollIntoView({block: 'center'}); } catch(e2) {}
          els[i].click();
          return '1';
        }
      }
    }
  } catch(e) {}
  return '0';
})();
''');
      return res != null && res.toString().contains('1');
    } catch (_) {
      return false;
    }
  }

  /// 同步结束后回写 Cookie：只在登录态健康（含关键令牌且未降级）时更新，避免被匿名会话覆盖而掉线
  Future<void> _persistCookiesIfHealthy(String originalCookies) async {
    try {
      final cookieManager = WebViewCookieManager();
      final map = <String, String>{};
      for (final host in const ['https://mobile.yangkeduo.com', 'https://yangkeduo.com']) {
        try {
          final list = await cookieManager.getCookies(domain: Uri.parse(host));
          for (final c in list) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) map[c.name] = c.value;
          }
        } catch (_) {}
      }
      if (map.isEmpty) return;

      final hasLoginToken = map.keys.any((k) =>
          k.contains('PDDAccessToken') ||
          k.contains('pdd_user_id') ||
          k.contains('pdduid') ||
          k.contains('AccessToken'));
      if (!hasLoginToken) {
        debugPrint('[PDD] skip cookie persist: no login token (keep stored credential)');
        return;
      }

      final merged = map.entries.map((e) => '${e.key}=${e.value}').join('; ');
      if (merged.length < (originalCookies.length * 0.6)) {
        debugPrint('[PDD] skip cookie persist: degraded set (${merged.length} < ${originalCookies.length})');
        return;
      }
      if (merged != originalCookies) {
        await PlatformAuthStore().saveCookies('pdd', merged);
        debugPrint('[PDD] cookies refreshed (len ${merged.length})');
      }
    } catch (e) {
      debugPrint('[PDD] persist cookies error: $e');
    }
  }

  /// 阶段 1：在页面上下文内 fetch 订单列表（结果不可用时自动重试）
  Future<String?> _fetchOrderList() async {
    final controller = _controller;
    if (controller == null) return null;

    // 优化：若当前 WebView 已停留在拼多多站点内，优先直接发起 API fetch，免去整页重新加载
    try {
      final currentUrl = await controller.currentUrl();
      if (currentUrl != null && currentUrl.contains('yangkeduo.com')) {
        final quickRaw = await _runOrderListFetch();
        if (quickRaw != null &&
            quickRaw.trimLeft().startsWith('{') &&
            quickRaw.length > 100 &&
            !quickRaw.contains('"error"')) {
          debugPrint('[PDD] Fast order list fetch hit (len=${quickRaw.length})');
          return quickRaw;
        }
      }
    } catch (_) {}

    await controller.loadRequest(Uri.parse('https://mobile.yangkeduo.com/orders.html'));
    // 轮询等待页面与 JS 运行时就绪
    await _awaitPageInteractive();

    for (var attempt = 1; attempt <= 2; attempt++) {
      final raw = await _runOrderListFetch();
      if (raw == null) {
        debugPrint('[PDD] order list attempt $attempt timeout');
      } else {
        var s = raw;
        if (s.startsWith('"') && s.endsWith('"')) {
          try {
            s = jsonDecode(s) as String;
          } catch (_) {}
        }
        // 被重定向到登录页 → 登录态失效，立即停止重试并上报
        if (s.contains('login.html') || s.contains('HTTPSTATUS:424')) {
          _lastIssue = '拼多多登录态已失效，请在「设置」中重新登录';
          await _authStore.setExpired('pdd', true);
          debugPrint('[PDD] session expired (status/redirect detected)');
          return null;
        }
        if (s.trimLeft().startsWith('{') && s.length > 100 && !s.contains('"error"')) {
          return s;
        }
        debugPrint('[PDD] order list attempt $attempt unusable (len=${s.length}, head=${s.take(160)})');
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  Future<String?> _runOrderListFetch() async {
    final controller = _controller;
    if (controller == null) return null;

    final completer = Completer<String>();
    _bridgeCompleter = completer;

    try {
      await controller.runJavaScript('''
(function(){
  function report(t){ try { PddBridge.postMessage(String(t)); } catch(e) {} }
  try {
    var uid = '';
    var m = document.cookie.match(/(?:pdd_user_id|pdduid)=([^;]+)/);
    if (m) uid = m[1];
    var url1 = '/proxy/api/api/aristotle/order_list_v4?pdduid=' + uid + '&page=1&type=all';
    fetch(url1, {credentials: 'include'})
      .then(function(r1){
        if (!r1.ok) { report('HTTPSTATUS:' + r1.status + '|' + location.href); return null; }
        return r1.json();
      })
      .then(function(d1){
        if (!d1) return;
        var orders = d1.orders || (d1.result && d1.result.orders) || [];
        if (orders.length >= 10) {
          // 第一页满 10 条时，延迟 300ms 平滑获取第 2 页，避免触发 429 风控
          setTimeout(function(){
            var url2 = '/proxy/api/api/aristotle/order_list_v4?pdduid=' + uid + '&page=2&type=all';
            fetch(url2, {credentials: 'include'})
              .then(function(r2){ return r2.ok ? r2.json() : null; })
              .then(function(d2){
                if (d2) {
                  var orders2 = d2.orders || (d2.result && d2.result.orders) || [];
                  orders = orders.concat(orders2);
                }
                report(JSON.stringify({orders: orders}));
              })
              .catch(function(){
                report(JSON.stringify({orders: orders}));
              });
          }, 300);
        } else {
          report(JSON.stringify({orders: orders}));
        }
      })
      .catch(function(e){ report('FETCHERR:' + String(e)); });
  } catch(e) {
    report('JSERR:' + String(e));
  }
})();
''');
    } catch (e) {
      debugPrint('[PDD] runJavaScript error: $e');
      _bridgeCompleter = null;
      return null;
    }

    try {
      final raw = await completer.future.timeout(const Duration(seconds: 6));
      _bridgeCompleter = null;
      return raw;
    } on TimeoutException {
      _bridgeCompleter = null;
      return null;
    }
  }

  static String _mapPddStatusToTag(String status, String info) {
    final s = status.toUpperCase();
    if (s == 'IN_CABINET') return '待取件';
    if (s == 'SEND') return '派件中';
    if (s == 'ARRIVAL' || s == 'DEPARTURE' || s == 'OTHER') return '运输中';
    if (s == 'GOT') return '已揽件';
    if (s == 'PICK') return '拣货';
    if (s == 'PRINT') return '打单';
    if (s == 'CONFIRM') return '配货';
    if (s == 'CREATE') return '已下单';
    if (s == 'SIGNED') return '已签收';
    if (info.contains('待取') || info.contains('自提') || info.contains('取件码')) return '待取件';
    if (info.contains('派件') || info.contains('派送')) return '派件中';
    if (info.contains('揽收') || info.contains('已揽')) return '已揽件';
    if (info.contains('发货')) return '已发货';
    return '运输中';
  }

  /// 从订单详情页（order.html）直接读取拼多多官方注入在 window.rawData 中的结构化物流数据
  ///
  /// 该数据源直接包含：运单号、快递公司、完整历史时间轴（expressInfo.traces 列表，含精确到秒的时间与原生状态），
  /// 比纯文本 DOM 正则扫描更精准，且无论 WebView 是否成功跳转都能拿到完整轨迹。
  Future<Map<String, dynamic>?> _extractOrderRawData() async {
    try {
      final res = await _controller?.runJavaScriptReturningResult('''
(function(){
  try {
    var d = window.rawData && window.rawData.data;
    if (!d) return '';
    var expressInfo = d.expressInfo;
    var orderButtons = d.orderButtons || [];
    var expressBtn = null;
    for (var i = 0; i < orderButtons.length; i++) {
      if (orderButtons[i].briefPrompt === '查看物流') {
        expressBtn = orderButtons[i];
        break;
      }
    }
    var expressUrl = (expressBtn && expressBtn.typeValue && expressBtn.typeValue.url) || '';
    
    return JSON.stringify({
      orderSn: d.orderSn || '',
      trackingNumber: d.trackingNumber || (expressInfo && expressInfo.trackingNumber) || '',
      shippingName: (d.shipping && d.shipping.shippingName) || (expressInfo && expressInfo.shippingName) || '',
      shippingAddress: d.shippingAddress || d.address || '',
      expressUrl: expressUrl,
      pddStatus: (expressInfo && expressInfo.pddStatus) || '',
      pddStatusDesc: (expressInfo && expressInfo.pddStatusDesc) || '',
      traces: (expressInfo && expressInfo.traces) || []
    });
  } catch(e) { return ''; }
})()
''');
      if (res == null) return null;
      var str = res.toString();
      if (str.startsWith('"') && str.endsWith('"')) {
        try {
          str = jsonDecode(str) as String;
        } catch (_) {
          str = str.substring(1, str.length - 1);
        }
      }
      if (str.trim().isEmpty) return null;
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 轮询等待拼多多页面注入的官方结构化数据（校验订单号以防串页）
  Future<Map<String, dynamic>?> _awaitOrderRawData(
    String requiredOrderSn, {
    Duration timeout = const Duration(milliseconds: 3000),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final data = await _extractOrderRawData();
      if (data != null && data['orderSn'] == requiredOrderSn) {
        return data;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return await _extractOrderRawData();
  }

  /// 阶段 2：进入订单详情页 / 物流轨迹页，抽取承运商、运单号、完整时间线与取件码
  Future<PddDetailResult?> _fetchOrderDetail(String orderSn, {Package? base}) async {
    final controller = _controller;
    if (controller == null || orderSn.isEmpty) return null;

    final sw = Stopwatch()..start();

    try {
      // 标准流程：加载当前订单详情页
      await _clearDom();
      await controller.loadRequest(
        Uri.parse('https://mobile.yangkeduo.com/order.html?order_sn=$orderSn'),
      );
      final t1 = sw.elapsedMilliseconds;

      // 关键优化：优先直接轮询 window.rawData.data 中的官方结构化物流数据
      // 服务端内联直出，通常 200~400ms 内即就绪且 100% 官方保真
      final rawData = await _awaitOrderRawData(orderSn, timeout: const Duration(milliseconds: 3000));
      final rawTraces = (rawData?['traces'] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final rawTrackingNo = (rawData?['trackingNumber'] as String?)?.trim() ?? '';
      final rawShippingName = (rawData?['shippingName'] as String?)?.trim() ?? '';
      var expressUrl = (rawData?['expressUrl'] as String?)?.trim();
      final t2 = sw.elapsedMilliseconds;

      final orderText = await _domText();

      // 判断该包裹是否已签收/已完成
      final isCompleted = base?.status == PackageStatus.pickedUp ||
          base?.status == PackageStatus.archived ||
          base?.status == PackageStatus.rejected ||
          rawData?['pddStatus'] == 'SIGNED' ||
          rawData?['pddStatusDesc'] == '已签收';

      String deep = '';
      bool navigated = false;
      String landedPath = '';

      // 只有未签收的包裹才需要继续深挖轨迹页提取取件码与驿站名；已签收包裹直接复用 order.html 的完整官方轨迹
      if (!isCompleted) {
        if (expressUrl == null || expressUrl.isEmpty) {
          expressUrl = await _extractExpressUrl();
        }
        if (expressUrl != null && expressUrl.isNotEmpty && !expressUrl.startsWith('http')) {
          expressUrl = 'https://mobile.yangkeduo.com/${expressUrl.startsWith('/') ? expressUrl.substring(1) : expressUrl}';
        }

        if (expressUrl != null && expressUrl.isNotEmpty) {
          await _clearDom();
          await controller.loadRequest(Uri.parse(expressUrl));
          navigated = true;
        } else {
          navigated = await _clickViewLogistics();
        }
        deep = await _awaitExpressTimelineText(
          timeout: Duration(milliseconds: navigated ? 3500 : 900),
        );
        try {
          final landed = await controller.currentUrl();
          if (landed != null) landedPath = Uri.parse(landed).path;
        } catch (_) {}
      }

      final t3 = sw.elapsedMilliseconds;
      final deepTsCount =
          RegExp(r'\d{4}[-/.]\d{2}[-/.]\d{2}\s+\d{2}:\d{2}').allMatches(deep).length;

      // 关键优化：deep（物流详情页）包含最新取件凭证/到站信息，放在最前；
      // orderText 附在后面补充地址/订单编号
      String text;
      if (deep.isNotEmpty && deep.length >= 80) {
        text = '$deep\n$orderText';
      } else {
        text = orderText;
      }

      final result = parseLogisticsText(
        text,
        orderSn: orderSn,
        fallbackTrackingNo: rawTrackingNo,
        fallbackCourier: courierFromName(rawShippingName),
        rawTraces: rawTraces,
      );
      debugPrint('[PDD] Detail[$orderSn] load=${t1}ms rawPoll=${t2 - t1}ms '
          'expressPoll=${t3 - t2}ms link=${expressUrl != null} landed=$landedPath '
          'deepLen=${deep.length} deepTs=$deepTsCount rawTraces=${rawTraces?.length ?? 0} '
          'total=${sw.elapsedMilliseconds}ms');
      // 若时间轴节点偏少（例如少于2个），尝试从 window.name 暂存的接口响应中递归扫描补全
      var curResult = result;
      if (curResult != null && _timelineNodeCount(curResult.rawTimelineJson) < 2) {
        try {
          final wName = await _readWindowName();
          final captures = parsePddWindowNameCaptures(wName);
          for (final cap in captures) {
            if (cap.url.contains(orderSn) ||
                cap.url.contains('shipping') ||
                cap.url.contains('trace') ||
                cap.url.contains('logistic')) {
              final root = jsonDecode(cap.body);
              final jsonNodes = extractPddTimelineFromJson(root);
              if (jsonNodes.isNotEmpty) {
                final jsonNodesStr = jsonEncode(jsonNodes);
                final mergedJson = mergeTimelineJson(curResult?.rawTimelineJson, jsonNodesStr);
                curResult = curResult?.copyWith(rawTimelineJson: mergedJson);
                debugPrint('[PDD] window.name fallback enriched ${jsonNodes.length} nodes for $orderSn');
              }
            }
          }
        } catch (e) {
          debugPrint('[PDD] window.name scan error: $e');
        }
      }

      if (curResult != null) {
        debugPrint('[PDD] Detail[$orderSn] courier=${curResult.courier.displayName} tracking=${curResult.trackingNo} '
            'status=${curResult.status.label} code="${curResult.pickupCode}" '
            'timelineNodes=${_timelineNodeCount(curResult.rawTimelineJson)}');
      }
      return curResult;
    } catch (e) {
      debugPrint('[PDD] _fetchOrderDetail error for $orderSn: $e');
      return null;
    }
  }

  /// 从订单详情页 DOM 中取出「查看物流」轨迹页链接
  ///
  /// 比模拟点击更可靠：部分订单的入口是 target=_blank / JS 新开窗口，
  /// 点击在单窗口 WebView 里会被直接丢弃（表现为点击成功但页面没跳转）。
  Future<String?> _extractExpressUrl() async {
    try {
      final res = await _controller?.runJavaScriptReturningResult('''
(function(){
  try {
    var as = document.querySelectorAll('a[href]');
    for (var i = 0; i < as.length; i++) {
      var h = as[i].getAttribute('href') || '';
      if (h.indexOf('goods_express') !== -1) return h;
    }
    var labels = ['查看物流','查物流','物流详情','物流信息','查看物流信息','物流轨迹','查看物流轨迹'];
    var els = document.querySelectorAll('div,span,p,button');
    for (var j = 0; j < els.length; j++) {
      var t = (els[j].innerText || '').trim();
      if (t.length === 0 || t.length > 12) continue;
      if (labels.indexOf(t) === -1) continue;
      var n = els[j];
      for (var k = 0; k < 6 && n; k++) {
        if (n.tagName === 'A' && n.getAttribute('href')) return n.getAttribute('href');
        n = n.parentElement;
      }
    }
  } catch(e) {}
  return '';
})()
''');
      var s = res.toString();
      if (s.startsWith('"') && s.endsWith('"')) {
        s = s.substring(1, s.length - 1);
      }
      s = s.trim();
      if (s.isEmpty) return null;
      if (!s.startsWith('http')) {
        s = 'https://mobile.yangkeduo.com/${s.startsWith('/') ? s.substring(1) : s}';
      }
      return s;
    } catch (_) {
      return null;
    }
  }

  /// 清空当前 DOM，避免读到上一个页面的残留文本造成串页误判
  Future<void> _clearDom() async {
    try {
      await _controller?.runJavaScript('if (document.body) document.body.innerText = "";');
    } catch (_) {}
  }

  /// 从 window.name 读取跨页暂存的网络捕获数据
  Future<String> _readWindowName() async {
    try {
      final r = await _controller?.runJavaScriptReturningResult(
        "(function(){var s=window.name||'';window.name='';return s;})()",
      );
      var text = r.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        try {
          text = jsonDecode(text) as String;
        } catch (_) {
          text = text.substring(1, text.length - 1);
        }
      }
      return text.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
    } catch (_) {
      return '';
    }
  }

  /// 从拼多多物流文本中解析结构化详情（支持订单详情页与物流轨迹页）
  static PddDetailResult? parseLogisticsText(
    String text, {
    String orderSn = '',
    String fallbackTrackingNo = '',
    CourierType fallbackCourier = CourierType.other,
    List<Map<String, dynamic>>? rawTraces,
    DateTime? now,
  }) {
    if (text.trim().isEmpty) return null;

    // 若传入了 orderSn，核验文本中出现的订单编号是否一致，防止读到上个页面的脏文本
    if (orderSn.isNotEmpty) {
      final orderSnMatch = RegExp(r'订单编号[:：\s]*([0-9\-]+)').firstMatch(text);
      if (orderSnMatch != null) {
        final extractedSn = orderSnMatch.group(1)!.trim();
        if (extractedSn.isNotEmpty && extractedSn != orderSn) {
          debugPrint('[PDD] OrderSn mismatch: expected $orderSn, found $extractedSn. Ignoring cross-page dirty text.');
          return null;
        }
      }
    }

    // 截断底部无关的推荐商品流（仅截断真正的推荐模块标题，避免误伤上方物流轨迹）
    const recommendationMarkers = [
      '猜你喜欢', '相关推荐', '热门推荐', '精选推荐', '更多推荐',
      '看了又看', '同款推荐', '为您推荐', '大家都在买', '热卖排行',
      '你可能还喜欢', '推荐商品', '猜你感兴趣',
    ];
    var cutAt = text.length;
    for (final m in recommendationMarkers) {
      final i = text.indexOf(m);
      if (i != -1 && i < cutAt) cutAt = i;
    }
    final logisticsText = text.substring(0, cutAt);
    final lines = logisticsText
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // 1) 优先匹配「快递公司: 运单号」复合行（如“中通快递: 79146191072186”、“邮政快递包裹: 9819812698898”）
    var courier = fallbackCourier != CourierType.other ? fallbackCourier : CourierType.other;
    var trackingNo = fallbackTrackingNo;

    final courierTrackPattern = RegExp(
      r'([\u4e00-\u9fa5A-Za-z]{2,10}(?:快递|速递|速运|包裹|物流)?)\s*[:：]\s*([A-Za-z0-9]{8,25})',
    );
    for (final line in lines) {
      if (line.contains('订单编号') || line.contains('收货地址') || line.contains('电话') || line.contains('自提点')) {
        continue;
      }
      final m = courierTrackPattern.firstMatch(line);
      if (m != null) {
        final cName = m.group(1)!.trim();
        final tNum = m.group(2)!.trim();
        final c = courierFromName(cName);
        if (c != CourierType.other && !tNum.contains('-')) {
          courier = c;
          trackingNo = tNum;
          break;
        }
      }
    }

    // 若未匹配到复合行，单独查找运单号与快递名称
    if (trackingNo.isEmpty) {
      final trackReg = RegExp(r'^([A-Za-z]{2,6}\d{8,20}|\d{10,20})$');
      for (final l in lines.take(15)) {
        final m = trackReg.firstMatch(l);
        if (m != null && !l.contains('-')) {
          trackingNo = m.group(1)!;
          break;
        }
      }
    }

    if (courier == CourierType.other) {
      courier = courierFromName(lines.take(12).join(' '));
    }

    // 依据运单号规则（前缀与号段）补齐承运商
    if (courier == CourierType.other && trackingNo.isNotEmpty) {
      courier = courierFromTrackingNumber(trackingNo);
    }

    if (courier == CourierType.other && fallbackCourier != CourierType.other) {
      courier = fallbackCourier;
    }

    // 2) 收货地址
    var address = '';
    final addrMatch = RegExp(r'收货地址[:：\s]*([^\n]{4,80})').firstMatch(logisticsText);
    if (addrMatch != null) {
      address = addrMatch.group(1)!.trim().replaceAll(RegExp(r'#[A-Za-z0-9]{4,}$'), '').trim();
    }

    // 3) 取件码：支持常规码与“取件出示[快递]单号后[四五\d]+位”
    var pickupCode = '';
    final codeMatch = RegExp(
      r'(?:取件码|提货码|取货码|凭码|取货凭证|验证码)[:：\s]*([A-Za-z0-9\-]{3,12})',
    ).firstMatch(logisticsText);
    if (codeMatch != null) pickupCode = codeMatch.group(1) ?? '';

    // 只有在页面明确含有出示单号/凭单号取件上下文时，才提取后五位
    final hasFiveCodeContext = logisticsText.contains('待取') ||
        logisticsText.contains('取件') ||
        logisticsText.contains('出示') ||
        logisticsText.contains('凭码') ||
        logisticsText.contains('提货');
    if (pickupCode.isEmpty && hasFiveCodeContext) {
      final fiveMatch = RegExp(
        r'(?:取件出示|出示)?(?:快递)?(?:单号)?后([四五\d]+)位[:：\s]*([0-9A-Za-z]{4,6})',
      ).firstMatch(logisticsText);
      if (fiveMatch != null) {
        final digits = fiveMatch.group(2) ?? '';
        if (digits.isNotEmpty) {
          pickupCode = '后${digits.length}位 $digits';
        }
      }
    }

    if (pickupCode.isEmpty && hasFiveCodeContext) {
      final altMatch = RegExp(r'(?:出示|凭)[\u4e00-\u9fa5]{0,6}后五位[:：\s]*([0-9A-Za-z]{5})').firstMatch(logisticsText);
      if (altMatch != null) {
        pickupCode = '后5位 ${altMatch.group(1)}';
      }
    }

    // 4) 最新物流状态与轨迹描述
    var status = PackageStatus.transit;
    var latestText = '';
    var statusFound = false;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (!statusFound) {
        final s = _statusFromLine(l);
        if (s != null) {
          status = s;
          statusFound = true;
          for (var j = i + 1; j < lines.length && j <= i + 4; j++) {
            final cand = lines[j];
            final isTimeOnly = RegExp(r'^\s*(?:[\u4e00-\u9fa5]{2,6}\s*)?\d{4}[-/.]\d{2}[-/.]\d{2}').hasMatch(cand) && cand.length < 32;
            if (cand.length >= 8 && _looksLikeTrace(cand) && !isTimeOnly) {
              latestText = cand;
              break;
            }
          }
          continue;
        }
      }
    }
    if (!statusFound) {
      final s = _statusFromLine(logisticsText);
      if (s != null) status = s;
    }
    if (latestText.isEmpty) {
      for (final l in lines) {
        if (l.length >= 10 && _looksLikeTrace(l)) {
          latestText = l;
          break;
        }
      }
    }
    latestText = latestText.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 5) 驿站名（支持“菜鸟驿站 | 示例小区北门店”、“已派送至【xxx】”）
    var stationName = '';
    final pipeStation = RegExp(
      r'(?:菜鸟驿站|多多驿站|兔喜生活|中通快递超市|顺丰速运|韵达超市|妈妈驿站)\s*[|｜·]\s*([^\n\r,，。】\]]{2,30})',
    ).firstMatch(logisticsText);
    if (pipeStation != null) {
      stationName = pipeStation.group(1)!.trim();
    }

    if (stationName.isEmpty) {
      final bracketStation = RegExp(
        r'(?:已派送至|派送至|到达|存入|放入|已送达|自提点|自提柜|自提门店|取件门店|驿站|门店)[:：\s]*【([^】]{2,30})】',
      ).firstMatch(logisticsText);
      if (bracketStation != null) {
        stationName = bracketStation.group(1)!.trim();
      }
    }

    if (stationName.isEmpty) {
      final cnMatch = RegExp(
        r'(?:菜鸟驿站|多多驿站|兔喜生活|中通快递超市|顺丰速运|韵达超市|妈妈驿站)\s*[【\[]?([^\n\r,，。】\]]{2,30})',
      ).firstMatch(logisticsText);
      if (cnMatch != null) {
        stationName = cnMatch.group(1)!.trim().replaceAll(RegExp(r'^[|｜·\s]+'), '');
      }
    }

    if (stationName.isEmpty &&
        (logisticsText.contains('驿站') ||
            logisticsText.contains('快递柜') ||
            logisticsText.contains('自提') ||
            logisticsText.contains('代收') ||
            logisticsText.contains('服务点') ||
            logisticsText.contains('门店'))) {
      final stationMatch = RegExp(
        r'([\u4e00-\u9fa5A-Za-z0-9（）()]{2,24}(?:驿站|快递柜|自提柜|自提点|代收点|服务点|超市|门店|便利店|服务站))',
      ).firstMatch(logisticsText);
      if (stationMatch != null) stationName = stationMatch.group(1) ?? '';
    }

    if (stationName.isNotEmpty && logisticsText.contains('菜鸟驿站') && !stationName.contains('菜鸟')) {
      stationName = '菜鸟驿站 · $stationName';
    }

    // 检查包裹是否已经到达自提点/待取件
    final hasArrivalKeywords = logisticsText.contains('已派送至') ||
        logisticsText.contains('待取件') ||
        logisticsText.contains('放入代收点') ||
        logisticsText.contains('代收点') ||
        logisticsText.contains('已到站') ||
        logisticsText.contains('已入库') ||
        logisticsText.contains('待自提') ||
        logisticsText.contains('已存放') ||
        logisticsText.contains('凭取件码') ||
        logisticsText.contains('出示单号') ||
        logisticsText.contains('出示快递单号');
    final isArrivedExpress = RegExp(r'(?:已送达|今天\s*\d{2}:\d{2}\s*送达|包裹已送达)').hasMatch(logisticsText) &&
        !logisticsText.contains('预计明日送达') &&
        !logisticsText.contains('预计后天送达') &&
        !logisticsText.contains('转运中心');
    final isAtPickupStation = RegExp(r'(?:已到达|已派送至|已送至|存入|放入)[^，,\n]{0,10}(?:自提点|驿站|自提柜|快递柜|门店|代收点)').hasMatch(logisticsText) &&
        !logisticsText.contains('发往');

    final isAtStation = hasArrivalKeywords || isArrivedExpress || isAtPickupStation;
    final isExplicitDelivery = status == PackageStatus.delivering ||
        logisticsText.contains('派送中') ||
        logisticsText.contains('派件中') ||
        logisticsText.contains('正在配送');

    // 只有非待发货、且确实到达驿站自提点或有取件码时，才认定为 arrived
    if (status != PackageStatus.pendingShipment &&
        (pickupCode.isNotEmpty || isAtStation) &&
        status != PackageStatus.pickedUp) {
      if (!isAtStation && isExplicitDelivery && pickupCode.isEmpty) {
        status = PackageStatus.delivering;
      } else {
        status = PackageStatus.arrived;
      }
    }

    if (status == PackageStatus.pendingShipment) {
      stationName = '';
      if (latestText.isEmpty) {
        for (final l in lines) {
          if (l.contains('预计') && l.contains('发货')) {
            latestText = l;
            break;
          }
        }
        if (latestText.isEmpty) latestText = '等待商家发货中';
      }
    }

    // 6) 高保真提取拼多多官方时间轴轨迹节点（图2完整对齐）
    final timelineNodes = <Map<String, String>>[];

    // 写入前统一规范化时间（解析不出则不写入），同一时间只保留一条；
    // 已有节点没有标签、新节点时间和正文相同且带标签时，用带标签的替换（DOM 兜底节点 tag 恒为空）
    void addNode(String tag, String rawTime, String text) {
      final time = normalizeTraceTime(rawTime, now: now);
      if (time == null) return;
      final idx = timelineNodes.indexWhere((n) => n['time'] == time);
      if (idx == -1) {
        timelineNodes.add({'tag': tag, 'time': time, 'text': text});
      } else if ((timelineNodes[idx]['tag'] ?? '').isEmpty &&
          tag.isNotEmpty &&
          (timelineNodes[idx]['text'] ?? '').trim() == text.trim()) {
        timelineNodes[idx] = {'tag': tag, 'time': time, 'text': text};
      }
    }

    // 优先注入拼多多官方结构化数据中的完整时间轴节点（expressInfo.traces 列表，含秒级时间与原生状态）
    if (rawTraces != null) {
      for (final t in rawTraces) {
        final info = (t['info'] ?? t['text'] ?? '').toString().trim();
        final timeStr = (t['time'] ?? '').toString().trim();
        final pddStatus = (t['status'] ?? '').toString().trim();
        if (info.isNotEmpty && timeStr.isNotEmpty) {
          final tag = _mapPddStatusToTag(pddStatus, info);
          addNode(tag, timeStr, info);
        }
      }
    }

    // 融合抗推荐流状态机解析 DOM 纯文本节点（防商品流混入）
    final domParsedNodes = parsePddDomTimeline(logisticsText, now: now);
    for (final node in domParsedNodes) {
      addNode(node['tag'] ?? '', node['time'] ?? '', node['text'] ?? '');
    }

    final timeRegex = RegExp(
      r'(?:([\u4e00-\u9fa5]{2,6})\s*)?(\d{4}[-/.]\d{2}[-/.]\d{2}\s+\d{2}:\d{2}(?::\d{2})?)',
    );

    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final m = timeRegex.firstMatch(l);
      if (m != null) {
        var tag = m.group(1) ?? '';
        final timeStr = m.group(2)!;

        // 若行内无标签但上一行为短状态标签（如“派件中”、“运输中”），继承该标签
        if (tag.isEmpty && i > 0) {
          final prev = lines[i - 1].trim();
          if (const ['派件中', '派送中', '运输中', '待取件', '已签收', '已发货', '揽收'].contains(prev)) {
            tag = prev;
          }
        }

        // 提取该节点描述：检查同行剩余或下一行
        var desc = l.replaceFirst(m.group(0)!, '').trim();
        // 如果残留的描述是空，或者残留的仅仅是短标签（长度小于4），真实轨迹在下一行
        if ((desc.isEmpty || desc.length < 4) && i + 1 < lines.length) {
          final nextLine = lines[i + 1].trim();
          if (!timeRegex.hasMatch(nextLine) && _looksLikeTrace(nextLine)) {
            desc = nextLine;
          }
        }

        // 节点描述必须非空且属于真实快递动态，绝不能是商品广告
        if (desc.isNotEmpty && desc.length >= 4 && _looksLikeTrace(desc)) {
          addNode(tag, timeStr, desc);
        }
      }
    }

    // 确保时间轴节点严格按时间戳降序排列（最新节点排在第一位）
    timelineNodes.sort((a, b) {
      final tA = a['time'] ?? '';
      final tB = b['time'] ?? '';
      return tB.compareTo(tA);
    });

    // 若成功抓取到官方时间轴，结合 LogisticsStatusEngine 状态机推导精准状态与最新动态
    if (timelineNodes.isNotEmpty) {
      latestText = timelineNodes.first['text'] ?? latestText;
      final derived = LogisticsStatusEngine.derive(
        events: timelineNodes,
        isPendingShipment: status == PackageStatus.pendingShipment,
        isOrderSigned: status == PackageStatus.pickedUp,
        pickupCode: pickupCode,
        stationName: stationName,
      );
      if (status != PackageStatus.pickedUp && status != PackageStatus.pendingShipment) {
        status = derived.status;
      }
    }

    final rawTimelineJson = timelineNodes.isNotEmpty ? jsonEncode(timelineNodes) : null;

    return PddDetailResult(
      courier: courier,
      trackingNo: trackingNo,
      status: status,
      pickupCode: pickupCode,
      stationName: stationName,
      address: address,
      latestText: latestText,
      rawTimelineJson: rawTimelineJson,
    );
  }

  static CourierType courierFromName(String text) {
    if (text.contains('顺丰')) return CourierType.sf;
    if (text.contains('京东')) return CourierType.jd;
    if (text.contains('中通')) return CourierType.zto;
    if (text.contains('圆通')) return CourierType.yt;
    if (text.contains('申通')) return CourierType.sto;
    if (text.contains('韵达')) return CourierType.yd;
    if (text.contains('极兔')) return CourierType.jt;
    if (text.contains('邮政') || text.contains('EMS')) return CourierType.ems;
    if (text.contains('德邦')) return CourierType.db;
    if (text.contains('百世')) return CourierType.best;
    return CourierType.other;
  }

  static CourierType courierFromTrackingNumber(String trackingNo) {
    final tn = trackingNo.trim().toUpperCase();
    if (tn.isEmpty) return CourierType.other;

    if (tn.startsWith('JT')) return CourierType.jt;
    if (tn.startsWith('SF')) return CourierType.sf;
    if (tn.startsWith('YT')) return CourierType.yt;
    if (tn.startsWith('ST')) return CourierType.sto;
    if (tn.startsWith('JD') || tn.startsWith('JDX') || tn.startsWith('JDD')) return CourierType.jd;
    if (tn.startsWith('ZTO') || tn.startsWith('ZTE')) return CourierType.zto;
    if (tn.startsWith('EA') || tn.startsWith('EB') || tn.startsWith('EY')) return CourierType.ems;

    final isDigits = RegExp(r'^\d+$').hasMatch(tn);
    if (isDigits) {
      final len = tn.length;
      // 中通：14位或15位，以 73, 75, 76, 77, 78, 79 开头，或 68, 61, 63 开头
      if ((len == 14 || len == 15) &&
          (tn.startsWith('73') ||
              tn.startsWith('75') ||
              tn.startsWith('76') ||
              tn.startsWith('77') ||
              tn.startsWith('78') ||
              tn.startsWith('79') ||
              tn.startsWith('68') ||
              tn.startsWith('61') ||
              tn.startsWith('63'))) {
        return CourierType.zto;
      }
      // 邮政快递包裹/EMS：13位，以 98, 97, 95, 10, 11, 12 开头
      if (len == 13 &&
          (tn.startsWith('98') ||
              tn.startsWith('97') ||
              tn.startsWith('95') ||
              tn.startsWith('10') ||
              tn.startsWith('11') ||
              tn.startsWith('12'))) {
        return CourierType.ems;
      }
      // 申通：12位、13位或15位，以 77, 55, 66, 33 开头
      if ((len == 12 || len == 13 || len == 15) &&
          (tn.startsWith('55') || tn.startsWith('66') || tn.startsWith('33') || (len == 12 && tn.startsWith('77')))) {
        return CourierType.sto;
      }
      // 韵达：13位或15位，以 43, 46, 31, 39, 12 开头
      if ((len == 13 || len == 15) &&
          (tn.startsWith('43') || tn.startsWith('46') || tn.startsWith('31') || tn.startsWith('39'))) {
        return CourierType.yd;
      }
      // 圆通：10位/12位/18位，以 88, 80, 81, 82, 83, 85 开头
      if ((len == 10 || len == 12 || len == 18) &&
          (tn.startsWith('88') || tn.startsWith('80') || tn.startsWith('81') || tn.startsWith('82') || tn.startsWith('83') || tn.startsWith('85'))) {
        return CourierType.yt;
      }
      // 极兔：15位，以 66, 68 开头
      if (len == 15 && (tn.startsWith('66') || tn.startsWith('68') || tn.startsWith('88'))) {
        return CourierType.jt;
      }
      // 顺丰：12位纯数字，以 01~09, 10, 11, 12 开头
      if (len == 12 &&
          (tn.startsWith('0') ||
              tn.startsWith('10') ||
              tn.startsWith('11') ||
              tn.startsWith('12'))) {
        return CourierType.sf;
      }
    }

    return CourierType.other;
  }

  /// 从一行文本推断包裹状态（委托给官方状态分类器）
  static PackageStatus? _statusFromLine(String line) => PddStatusClassifier.resolveLine(line);

  static bool _looksLikeTrace(String line) {
    final text = line.trim();
    if (text.length < 5 || text.length > 250) return false;

    // 严厉拦截商品标题、规格、广告特征，防止把商品营销信息误判为物流轨迹
    const goodsMarketingKeywords = [
      '天内发货', '小时内发货', '全款', '正版', '玩偶', '手撕', '蛋糕', '煎饺',
      '鸡蛋', '米哈游', 'mihoyo', '崩坏', '星穹铁道', '抱抱娃娃', '包邮',
      '保质期', '规格', '多种吃法', '退货包运费', '券后', '免运费', '实付',
      '售后无忧', '买1送', '买一送', '件套', '好吃', '零食', '旗舰店',
      '专卖店', '百亿补贴',
    ];
    final lower = text.toLowerCase();
    if (goodsMarketingKeywords.any(lower.contains)) return false;

    if (text.contains('订单编号') || text.contains('收货地址') || text.contains('复制')) return false;
    if (text.contains('即将恢复原价') || text.contains('本店已拼') || text.contains('商品快照')) return false;
    if (text.contains('待付款') && text.contains('待收货')) return false;
    if (text.contains('全部') && text.contains('评价')) return false;

    // 必须包含真实的快递物流动态动词（涵盖从下单、拣货、发货、揽件、转运到派送全生命周期）
    const traceKeywords = [
      '快件', '包裹', '已发往', '离开', '到达', '派送', '派件', '签收',
      '揽收', '转运', '投递', '取件', '出库', '配送', '运输', '送达',
      '等待揽收', '已揽件', '正在为您派件', '正在派送', '妥投',
      '已发货', '商家已发货', '通知快递', '拣货', '配货', '拣货单',
      '已下单', '订单确认', '提交订单', '等待系统确认', '通知商家',
    ];
    return traceKeywords.any(text.contains);
  }

  // ────────────────── 解析 ──────────────────

  @visibleForTesting
  dynamic parseOrderForTest(Map<String, dynamic> o) => _parseOrder(o);

  _ParsedOrder? _parseOrder(Map<String, dynamic> o) {
    final orderSn = _firstString(o, const ['order_sn', 'orderSn', 'order_id', 'orderId', 'mall_order_sn'])
        .ifBlank(_firstStringDeep(o, const ['order_sn', 'orderSn'], 3));
    final statusPrompt = _firstString(o, const [
      'order_status_prompt', 'order_prompt', 'status_prompt_text',
      'order_status_text', 'status_desc', 'statusDesc', 'order_status',
    ]).ifBlank(_firstStringDeep(o, const ['order_status_prompt', 'status_desc'], 3));

    final trackingNo = _firstString(o, const [
      'tracking_number', 'tracking_no', 'mail_no', 'mailNo', 'express_no', 'logistics_no', 'waybill_no',
    ]).ifBlank(orderSn);

    if (trackingNo.isEmpty) return null;

    final rawGoodsName = _firstStringDeep(o, const [
      'goods_name', 'goodsName', 'goods_title', 'goods_brief', 'product_name', 'item_name',
    ], 4);
    final goodsName = GoodsNameCleaner.clean(rawGoodsName).ifBlank('拼多多包裹');

    var goodsPic = _firstStringDeep(o, const [
      'goods_image_url', 'goodsImageUrl', 'image_url', 'hd_thumb_url', 'thumb_url', 'goods_thumb_url',
    ], 4);
    if (goodsPic.startsWith('//')) goodsPic = 'https:$goodsPic';

    final descText = _firstStringDeep(o, const [
      'tracking_desc', 'logistics_desc', 'bottom_left_content', 'status_desc', 'desc', 'text',
    ], 4);
    final allText = '$statusPrompt $descText';

    // 列表接口偶尔直接带取件码
    var pickupCode = '';
    final codeMatch = RegExp(r'(?:取件码|提货码|取货码|凭码)[:：\s]*([A-Za-z0-9\-]{3,12})').firstMatch(allText);
    if (codeMatch != null) pickupCode = codeMatch.group(1) ?? '';

    var stationName = '';
    final bracketMatch = RegExp(r'(?:已派送至|派送至|到达|存入|放入|已送达|自提点|自提柜|自提门店|取件门店|驿站|门店)[:：\s]*【([^】]{2,30})】').firstMatch(allText);
    if (bracketMatch != null) {
      stationName = bracketMatch.group(1)!.trim();
    } else {
      final stationMatch = RegExp(r'([\u4e00-\u9fa5A-Za-z0-9（）()]{2,24}(?:驿站|快递柜|自提柜|自提点|代收点|服务点|超市|门店|便利店))').firstMatch(allText);
      if (stationMatch != null) stationName = stationMatch.group(1) ?? '';
    }
    if (stationName.isNotEmpty && allText.contains('菜鸟驿站') && !stationName.contains('菜鸟')) {
      stationName = '菜鸟驿站 · $stationName';
    }

    // 使用拼多多官方状态分类引擎归类包裹状态
    final status = PddStatusClassifier.resolve(
      statusPrompt: statusPrompt,
      logisticsDesc: descText,
      fullText: allText,
      pickupCode: pickupCode,
    );
    debugPrint('[PDD LIST] sn=$orderSn status=${status.label} promptLen=${statusPrompt.length} descLen=${descText.length}');

    // 一次性输出「待收货」订单对象的字段名（仅键名，不含值），用于定位官方二级标签字段
    if (_listKeysDumpedCount < 2 && statusPrompt.contains('待收货')) {
      _listKeysDumpedCount++;
      o.forEach((k, v) {
        if (v is String && v.trim().isNotEmpty) {
          debugPrint('[PDD LIST KEY] $k (len=${v.trim().length})');
        }
      });
    }

    final courier = _resolveCourier(o, trackingNo: trackingNo, text: allText);

    final pkg = Package(
      id: 'PDD_${orderSn.ifBlank(trackingNo)}',
      trackingNumber: trackingNo,
      courier: courier,
      goodsName: goodsName,
      goodsImageUrl: goodsPic.isNotEmpty ? goodsPic : null,
      stationName: (status == PackageStatus.pendingShipment || status == PackageStatus.transit || status == PackageStatus.delivering)
          ? null
          : (stationName.isNotEmpty ? stationName : null),
      pickupCode: pickupCode,
      location: '',
      platform: 'pdd',
      description: descText,
      urgency: LogisticsStatusEngine.urgencyFor(status: status, pickupCode: pickupCode),
      status: status,
      addedAt: DateTime.now(),
    );

    // 所有未完成的活跃订单（待取件、派送中、运输中）均需同步完整官方物流时间线与详细动态
    final isCompleted = status == PackageStatus.pickedUp ||
        status == PackageStatus.archived ||
        status == PackageStatus.rejected;
    final needsCode = !isCompleted && status != PackageStatus.pendingShipment;

    // 若订单已退款/关闭，但商家已发货并存在真实运单号，说明包裹仍在物理运输中，不予过滤
    final hasActiveTracking = trackingNo.isNotEmpty && trackingNo != orderSn;
    final isClosedOrRefunded = statusPrompt.contains('退款') || statusPrompt.contains('已关闭') || statusPrompt.contains('取消');
    final isFiltered = isClosedOrRefunded && !hasActiveTracking;

    return _ParsedOrder(
      package: pkg,
      orderMeta: _PddOrder(pkg: pkg),
      needsPickupCode: needsCode,
      isFiltered: isFiltered,
    );
  }

  List<Map<String, dynamic>> _extractOrders(String jsonStr) {
    final result = <Map<String, dynamic>>[];
    dynamic root;
    try {
      root = jsonDecode(jsonStr);
    } catch (e) {
      debugPrint('[PDD] JSON decode failed: $e');
      return result;
    }

    const orderKeys = ['order_sn', 'orderSn', 'order_id', 'mall_order_sn', 'order_no'];
    const trackKeys = ['tracking_number', 'tracking_no', 'mail_no', 'mailNo', 'express_no', 'logistics_no'];

    void walk(dynamic node) {
      if (node is Map) {
        final m = node.cast<String, dynamic>();
        final isOrder = orderKeys.any((k) => m[k] is String || m[k] is num) ||
            trackKeys.any((k) => m[k] is String || m[k] is num);
        if (isOrder) {
          result.add(m);
        } else {
          for (final v in m.values) {
            walk(v);
          }
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    walk(root);
    return result;
  }

  String _firstString(Map<String, dynamic> obj, List<String> keys) {
    for (final k in keys) {
      final v = obj[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (v is num) return v.toString();
    }
    return '';
  }

  String _firstStringDeep(dynamic node, List<String> keys, int depth) {
    if (depth <= 0) return '';
    if (node is Map) {
      for (final k in keys) {
        final v = node[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      for (final v in node.values) {
        final r = _firstStringDeep(v, keys, depth - 1);
        if (r.isNotEmpty) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _firstStringDeep(v, keys, depth - 1);
        if (r.isNotEmpty) return r;
      }
    }
    return '';
  }

  CourierType _resolveCourier(Map<String, dynamic> o, {String trackingNo = '', String text = ''}) {
    final company = _firstStringDeep(o, const [
      'shipping_name', 'ship_name', 'shipping_company', 'shipping_company_name',
      'logistics_company_short_name', 'logistics_company', 'logisticsCompanyName',
      'express_company_name', 'express_company', 'express_name',
      'company_name', 'company',
    ], 3);
    if (company.isNotEmpty) {
      final c = courierFromName(company);
      if (c != CourierType.other) return c;
    }
    if (text.isNotEmpty) {
      final c = courierFromName(text);
      if (c != CourierType.other) return c;
    }
    if (trackingNo.isNotEmpty) {
      final c = courierFromTrackingNumber(trackingNo);
      if (c != CourierType.other) return c;
    }
    return CourierType.other;
  }
}

class _ParsedOrder {
  final Package package;
  final _PddOrder orderMeta;
  final bool needsPickupCode;
  final bool isFiltered;

  _ParsedOrder({
    required this.package,
    required this.orderMeta,
    required this.needsPickupCode,
    required this.isFiltered,
  });
}

/// 物流时间线缓存条目（支持分级 TTL 机制）
class _TimelineCache {
  /// 抓取当时「订单列表接口」返回的最新轨迹描述，用作变化指纹
  final String latestTrace;

  /// 抓取到的完整时间线 JSON
  final String? timelineJson;

  /// 详情页解析出的最新轨迹文案（比列表接口更完整，用于缓存命中时保持卡片文案一致）
  final String latestText;

  /// 缓存生成时间
  final DateTime cachedAt;

  /// 包裹当前状态（不同生命周期拥有不同的新鲜度 TTL）
  final PackageStatus status;

  /// 时间线节点数量（节点越多说明轨迹已抓全，可放宽刷新频率）
  final int nodeCount;

  /// 软件依据时间轴稳定性推导出的建议下次同步时间间隔
  final Duration recommendedSyncInterval;

  _TimelineCache(
    this.latestTrace,
    this.timelineJson,
    this.latestText, {
    DateTime? cachedAt,
    this.status = PackageStatus.transit,
    this.nodeCount = 0,
    this.recommendedSyncInterval = const Duration(minutes: 30),
  }) : cachedAt = cachedAt ?? DateTime.now();

  /// 基于时间轴稳定性动态推导的新鲜度判定
  bool isFresh() {
    // 关键机制：若时间轴严重残缺（≤1 个节点），绝不盲目命中缓存，允许深挖补齐官方完整多节点轨迹
    if (nodeCount <= 1 &&
        status != PackageStatus.pickedUp &&
        status != PackageStatus.archived &&
        status != PackageStatus.rejected) {
      return false;
    }
    final age = DateTime.now().difference(cachedAt);
    return age < recommendedSyncInterval;
  }
}

class _PddOrder {
  final Package pkg;
  _PddOrder({required this.pkg});
}

class PddDetailResult {
  final CourierType courier;
  final String trackingNo;
  final PackageStatus status;
  final String pickupCode;
  final String stationName;
  final String address;
  final String latestText;
  final String? rawTimelineJson;

  List<Map<String, String>> get parsedTimelineNodes {
    if (rawTimelineJson == null || rawTimelineJson!.isEmpty) return const [];
    try {
      final list = jsonDecode(rawTimelineJson!) as List<dynamic>;
      return list.map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) {
      return const [];
    }
  }

  PddDetailResult({
    required this.courier,
    required this.trackingNo,
    required this.status,
    required this.pickupCode,
    required this.stationName,
    required this.address,
    required this.latestText,
    this.rawTimelineJson,
  });

  PddDetailResult copyWith({
    CourierType? courier,
    String? trackingNo,
    PackageStatus? status,
    String? pickupCode,
    String? stationName,
    String? address,
    String? latestText,
    String? rawTimelineJson,
  }) {
    return PddDetailResult(
      courier: courier ?? this.courier,
      trackingNo: trackingNo ?? this.trackingNo,
      status: status ?? this.status,
      pickupCode: pickupCode ?? this.pickupCode,
      stationName: stationName ?? this.stationName,
      address: address ?? this.address,
      latestText: latestText ?? this.latestText,
      rawTimelineJson: rawTimelineJson ?? this.rawTimelineJson,
    );
  }
}

/// 拼多多官方状态分类引擎
/// 全面对齐拼多多 App 官方层级分类体系：
/// 1. 待付款 (unpaid)
/// 2. 待发货 (pendingShipment) -> 对应官方【待发货】Tab
/// 3. 待收货 (receiving) -> 对应官方【待收货】Tab，划分为4个官方二级标签：
///    - 待取件 (arrived) -> 对应官方【待取件】小标签（已送达自提点/驿站/柜，凭码取件）
///    - 派送中 (delivering) -> 对应官方【派件中】小标签（快递员配送中，尚未到站）
///    - 运输中 (transit) -> 对应官方【运输中】小标签（干线物流中转在途）
///    - 已签收 (pickedUp) -> 对应官方【已签收】小标签（用户已收货妥投）
class PddStatusClassifier {
  /// 整单文本 → 状态（始终返回状态，兜底为「运输中」）
  static PackageStatus resolve({
    required String statusPrompt,
    String logisticsDesc = '',
    String fullText = '',
    String pickupCode = '',
  }) {
    return _classify(
          statusPrompt: statusPrompt,
          logisticsDesc: logisticsDesc,
          fullText: fullText,
          pickupCode: pickupCode,
          lineMode: false,
        ) ??
        PackageStatus.transit;
  }

  /// 单行文本 → 状态；未命中任何状态信号时返回 null
  ///
  /// 用于逐行扫描物流轨迹：只有真正含状态信号的行才参与判定，
  /// 避免被「圆通速递: YT123456」这类表头行抢先判成在途。
  static PackageStatus? resolveLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return null;
    return _classify(
      statusPrompt: '',
      logisticsDesc: '',
      fullText: t,
      pickupCode: '',
      lineMode: true,
    );
  }

  static PackageStatus? _classify({
    required String statusPrompt,
    required String logisticsDesc,
    required String fullText,
    required String pickupCode,
    required bool lineMode,
  }) {
    final prompt = statusPrompt.trim();
    final desc = logisticsDesc.trim();
    var all = '$prompt $desc $fullText'.trim();

    // 剔除拼多多移动端顶部导航栏 Tab 串的干扰（如“全部 待付款 待分享 待发货 待收货 评价”）：
    // 只删除「全部 → 评价」这一段连续出现的导航串本身。
    // 不能按词全局 replaceAll，否则正文里真实的「待发货」轨迹会被一并删掉而误判成运输中。
    final navBar = RegExp(
      r'全部[\s|｜·/、,，]*待付款[\s|｜·/、,，]*(?:待分享[\s|｜·/、,，]*)?'
      r'待发货[\s|｜·/、,，]*待收货[\s|｜·/、,，]*(?:待评价|评价)',
    );
    all = all.replaceFirst(navBar, ' ').trim();

    // 0. 已拒收 / 退回发件人（终结态，优先于签收与到件判定）
    if (LogisticsStatusEngine.isRejectionSignal(prompt) ||
        LogisticsStatusEngine.isRejectionSignal(desc) ||
        LogisticsStatusEngine.isRejectionSignal(all)) {
      return PackageStatus.rejected;
    }

    // 1. 已签收 / 交易成功 (拼多多官方【已签收】标签 / 交易成功 / 待确认收货)
    if (prompt.contains('已签收') ||
        prompt.contains('交易成功') ||
        prompt.contains('待评价') ||
        prompt.contains('已完成') ||
        prompt.contains('已收货') ||
        desc.startsWith('已签收') ||
        desc.startsWith('已妥投') ||
        desc.contains('妥投签收') ||
        all.contains('已签收') ||
        all.contains('已妥投')) {
      return PackageStatus.pickedUp;
    }

    // 2. 待发货 (拼多多官方【待发货】Tab)
    if (prompt.contains('待发货') ||
        prompt.contains('未发货') ||
        prompt.contains('待出库') ||
        prompt.contains('等待发货') ||
        all.contains('待发货') ||
        all.contains('未发货') ||
        all.contains('待出库') ||
        all.contains('等待发货') ||
        all.contains('预计拼单成功后') ||
        all.contains('等待商家发货')) {
      return PackageStatus.pendingShipment;
    }

    // 3. 待取件 (拼多多官方【待取件】标签)：
    // 快件已派送至末端自提点/驿站/自提柜/代收点，等待用户提取
    final hasStationArrival = desc.contains('已派送至') ||
        desc.contains('待取件') ||
        desc.contains('待自提') ||
        desc.contains('已入库') ||
        desc.contains('已到站') ||
        desc.contains('已到驿站') ||
        desc.contains('凭取件码') ||
        desc.contains('凭提货码') ||
        desc.contains('出示单号') ||
        desc.contains('取件出示') ||
        all.contains('已派送至') ||
        all.contains('待取件') ||
        all.contains('凭取件码') ||
        prompt.contains('待取') ||
        prompt.contains('待自提') ||
        prompt.contains('已到站') ||
        prompt.contains('已到驿站') ||
        RegExp(r'(?:已到达|已派送至|已送至|放入|存入)[^，,\n]{0,10}(?:自提点|驿站|自提柜|快递柜|门店|代收点)').hasMatch(all);

    // 干线中转排除：转运中心送达并非自提点到件
    final isTransferTransit = all.contains('转运中心') && !all.contains('自提点') && !all.contains('驿站') && !all.contains('代收点');
    // 在途信号：文本明确处于干线运输/派送阶段时，取件码不足以独立证明已到站，
    // 否则历史残留的脏取件码会把在途包裹误锁成「待取件」。
    final hasInTransitSignal = RegExp(r'(运输中|派件中|派送中|已发往|已离开|转运中心|分拨中心|集散中心|分拣中心)').hasMatch(all);

    if (!isTransferTransit && hasStationArrival) {
      return PackageStatus.arrived;
    }
    if (!isTransferTransit && pickupCode.isNotEmpty && !hasInTransitSignal) {
      return PackageStatus.arrived;
    }

    // 4. 派送中 (拼多多官方【派件中】标签)：
    // 既包含快递员正在派送，也包含拼多多把「已到达/发往派件网点」归入的派件中阶段
    if (prompt.contains('派送') ||
        prompt.contains('派件') ||
        prompt.contains('正在配送') ||
        all.contains('派件') ||
        all.contains('派送') ||
        RegExp(r'(?:已到达|到达|发往|离开|存放|送至)[^，,\n]{0,12}(?:网点|营业部|分部|派件站|派送站|配送站)').hasMatch(all)) {
      return PackageStatus.delivering;
    }

    // 5. 运输中 (拼多多官方【运输中】标签)：干线中转或常规运输在途中
    if (lineMode) {
      const transitSignals = [
        '运输中', '已发往', '发往', '已离开', '离开', '已揽收', '揽收',
        '已发出', '发出', '到达', '转运中心', '分拨中心', '集散中心', '分拣中心', '揽件',
      ];
      if (!transitSignals.any(all.contains)) return null;
    }
    return PackageStatus.transit;
  }
}

extension on String {
  String ifBlank(String fallback) => trim().isEmpty ? fallback : this;
  String take(int n) => length <= n ? this : substring(0, n);
}
