/// 京东商城真实连接器 - 采用双引擎（接口拦截 + DOM提取），精准抓取「待收货」在途快递，过滤外卖/秒送/已完成
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/engine/logistics_status_engine.dart';
import '../../core/models/package.dart';
import '../../core/models/package_status.dart';
import '../../core/parser/trace_time.dart';
import '../../core/sanitizer/goods_name_cleaner.dart';
import '../storage/platform_auth_store.dart';
import 'jd_delivery_filter.dart';
import 'jd_trace_parser.dart';
import 'platform_connector.dart';
import 'concurrent_limiter.dart';

void _logJd(String msg) {
  debugPrint(msg);
  try {
    final f = File('/data/data/com.example.pickup_app/app_flutter/jd_sync.log');
    f.writeAsStringSync('[${DateTime.now().toString().substring(11, 19)}] $msg\n', mode: FileMode.append);
  } catch (_) {}
}

class JdH5Connector implements PlatformConnector {
  final PlatformAuthStore _authStore;
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  // 直接打开订单列表，默认筛选待收货
  static const _orderUrl =
      'https://trade.m.jd.com/order/orderlist_jdm.shtml';

  JdH5Connector({PlatformAuthStore? authStore})
      : _authStore = authStore ?? PlatformAuthStore();

  @override
  String get platformId => 'jd';

  @override
  String get displayName => '京东商城';

  @override
  String get brandColorHex => '#E1251B';

  @override
  Future<bool> isAuthenticated() async => _authStore.isBound('jd');

  @override
  Future<void> cancelSync() async {}

  @override
  String? get lastIssue => _lastIssue;

  /// 用户重新授权后清理上一次的失效提示
  void clearLastIssue() {
    _lastIssue = null;
  }

  String? _lastIssue;
  WebViewController? _controller;
  final List<String> _capturedJsonList = [];
  Completer<void>? _orderCapturedCompleter;
  final List<String> _capturedLogisticsJson = [];
  Completer<void>? _logisticsCapturedCompleter;

  @override
  Stream<Package> streamSync() async* {
    final cookies = _authStore.getCookies('jd');
    if (cookies == null || cookies.trim().isEmpty) {
      _logJd('[JD] No cookies, skip');
      return;
    }

    _lastIssue = null;
    _capturedJsonList.clear();
    _logJd('[JD] Starting sync with cookies (len: ${cookies.length})');
    await _injectCookies(cookies);

    final WebViewController controller;
    if (_controller != null) {
      controller = _controller!;
    } else {
      controller = WebViewController();
      _controller = controller;
      controller
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(_ua)
        ..addJavaScriptChannel(
          'JdBridge',
          onMessageReceived: (JavaScriptMessage msg) {
            final text = msg.message;
            if (text.contains('orderList')) {
              _logJd('[JD Hook] Captured order_list_m response (len: ${text.length})');
              _capturedJsonList.add(text);
              final c = _orderCapturedCompleter;
              if (c != null && !c.isCompleted) c.complete();
              try {
                File('/data/data/com.example.pickup_app/app_flutter/jd_order_list.json').writeAsStringSync(text);
              } catch (_) {}
            } else if (text.contains('tracePointVOList') || text.contains('carriageId')) {
              _logJd('[JD Hook] Captured logistics response (len: ${text.length})');
              _capturedLogisticsJson.add(text);
              final c = _logisticsCapturedCompleter;
              if (c != null && !c.isCompleted) c.complete();
            }
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (url) {
              _injectNetworkHook(controller);
            },
            onNavigationRequest: (request) {
              final lower = request.url.toLowerCase();
              if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onWebResourceError: (error) {
              if (error.isForMainFrame ?? false) {
                _logJd('[JD] main frame error: ${error.errorCode} ${error.description}');
              }
            },
          ),
        );
    }

    final completer = Completer<void>();
    _orderCapturedCompleter = completer;

    try {
      // 1) 注入请求拦截钩子并直接导航到订单列表（消除加载 home.m.jd.com 造成的 10s 死等）
      _logJd('[JD] Navigating directly to orderlist_jdm.shtml...');
      await controller.loadRequest(Uri.parse(_orderUrl));
      await _injectNetworkHook(controller);

      // 2) 极速拦截通道：等待网络钩子捕获 order_list_m 接口返回，最多等待 3.5 秒（通常 1~2 秒即可截获）
      try {
        await completer.future.timeout(const Duration(milliseconds: 3500));
        _logJd('[JD] Fast hook capture hit! Captured ${_capturedJsonList.length} JSON responses');
      } on TimeoutException {
        _logJd('[JD] Hook fast path timed out (3.5s), proceeding to fallback check');
      } finally {
        _orderCapturedCompleter = null;
      }

      final orders = <_JdOrder>[];

      // 3) 优先从拦截到的 JSON 响应中解析订单
      if (_capturedJsonList.isNotEmpty) {
        for (final jsonStr in _capturedJsonList) {
          orders.addAll(_parseOrdersFromJson(jsonStr));
        }
      }

      // 4) 仅在未拦截到 JSON 时才执行耗时的 DOM 兜底与登录态校验
      if (orders.isEmpty) {
        final landedUrl = await _locationHref(controller);
        _logJd('[JD] Fallback landed: $landedUrl');
        if (landedUrl.contains('plogin') || (landedUrl.contains('login') && !landedUrl.contains('orderlist'))) {
          _lastIssue = '京东登录态已失效，请在「设置」中重新登录';
          await _authStore.setExpired('jd', true);
          return;
        }

        // 尝试等待 DOM 渲染并提取
        await _awaitPageReady();
        final rawExtracted = await _extractWaitReceiveOrdersViaJs(controller);
        if (rawExtracted != null && rawExtracted.isNotEmpty) {
          orders.addAll(_parseExtractedOrdersFromDom(rawExtracted));
        }
      }

      // 去重并排除已归档订单（外卖/秒送已在 _parseOrdersFromJson 按快递白名单过滤）
      final validOrders = <String, _JdOrder>{};
      for (final o in orders) {
        if (o.status == PackageStatus.archived) {
          continue;
        }
        validOrders[o.orderId] = o;
      }

      _logJd('[JD] Final valid shopping orders: ${validOrders.length}');

      // ⚡ 优化：并发拉取物流详情（限制并发数为 3）
      final executor = ThrottledExecutor(
        maxConcurrent: 3,
        minDelay: const Duration(milliseconds: 150),
        maxDelay: const Duration(milliseconds: 350),
      );

      final detailTasks = validOrders.values.where((o) => o.progressLink.isNotEmpty).map((o) {
        return () => _fetchLogisticsDetail(o.orderId, o.progressLink).then((detail) {
          return {'orderId': o.orderId, 'detail': detail};
        });
      }).toList();

      final results = await executor.executeAll(detailTasks);

      // 构建 orderId -> detail 的映射
      final detailMap = <String, _JdLogisticsDetail?>{};
      for (final result in results) {
        final orderId = result['orderId'] as String;
        final detail = result['detail'] as _JdLogisticsDetail?;
        detailMap[orderId] = detail;
      }

      for (final o in validOrders.values) {
        // 从映射中获取物流详情
        final detail = detailMap[o.orderId];

        final timelineJson = (detail != null && detail.timelineNodes.isNotEmpty)
            ? jsonEncode(detail.timelineNodes)
            : null;

        final status = detail != null
            ? LogisticsStatusEngine.derive(
                events: detail.timelineNodes,
                isPendingShipment: o.status == PackageStatus.pendingShipment,
                isOrderSigned: o.status == PackageStatus.pickedUp,
                pickupCode: o.pickupCode,
                stationName: o.stationName,
              ).status
            : o.status;

        _logJd('[JD Yield] Order: ${o.goodsName}, id: ${o.orderId}, status: ${status.label}, '
            'tracking=${detail?.trackingNumber ?? ''} nodes=${detail?.timelineNodes.length ?? 0}');

        yield Package(
          id: 'JD_${o.orderId}',
          trackingNumber: (detail != null && detail.trackingNumber.isNotEmpty)
              ? detail.trackingNumber
              : o.orderId,
          courier: CourierType.jd,
          goodsName: o.goodsName.isNotEmpty ? o.goodsName : '京东商品快件',
          goodsImageUrl: o.imageUrl.isNotEmpty ? o.imageUrl : null,
          pickupCode: o.pickupCode,
          stationName: o.stationName.isNotEmpty ? o.stationName : '京东自提/配送',
          location: (detail != null && detail.address.isNotEmpty) ? detail.address : o.statusText,
          platform: 'jd',
          urgency: LogisticsStatusEngine.urgencyFor(status: status, pickupCode: o.pickupCode),
          status: status,
          addedAt: DateTime.now(),
          rawTimelineJson: timelineJson,
        );
      }
    } catch (e, stack) {
      _logJd('[JD] streamSync error: $e\n$stack');
    } finally {
      await _persistJdCookiesIfHealthy(cookies);
    }
  }

  /// 同步完成后回写最新 Cookie，防止 pt_key 丢失或数据萎缩
  Future<void> _persistJdCookiesIfHealthy(String originalCookies) async {
    try {
      final cm = WebViewCookieManager();
      final map = <String, String>{};
      for (final host in const [
        'https://www.jd.com',
        'https://trade.m.jd.com',
        'https://wqs.jd.com',
        'https://api.m.jd.com',
        'https://home.m.jd.com',
        'https://plogin.m.jd.com',
      ]) {
        try {
          final list = await cm.getCookies(domain: Uri.parse(host));
          for (final c in list) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) {
              map[c.name] = c.value;
            }
          }
        } catch (_) {}
      }
      if (map.isEmpty) return;

      final merged = map.entries.map((e) => '${e.key}=${e.value}').join('; ');
      if (isJdCookieHealthy(originalCookies, merged)) {
        if (merged != originalCookies) {
          await _authStore.saveCookies('jd', merged);
          _logJd('[JD] cookies refreshed (len: ${merged.length})');
        }
      } else {
        _logJd('[JD] skip cookie persist: failed health check (pt_key missing or degraded)');
      }
    } catch (e) {
      _logJd('[JD] persist cookies error: $e');
    }
  }

  /// 导航到订单物流跟踪页：双轨机制（优先拦截接口，超时走 DOM 纯文本状态机兜底）
  Future<_JdLogisticsDetail?> _fetchLogisticsDetail(String orderId, String progressLink) async {
    final controller = _controller;
    if (controller == null) return null;
    _capturedLogisticsJson.clear();
    final completer = Completer<void>();
    _logisticsCapturedCompleter = completer;
    try {
      await controller.loadRequest(Uri.parse(progressLink));
      try {
        await completer.future.timeout(const Duration(milliseconds: 3000));
      } on TimeoutException {
        // 页面未触发物流接口，继续走 DOM 兜底
      } finally {
        _logisticsCapturedCompleter = null;
      }
      if (_capturedLogisticsJson.isNotEmpty) {
        final parsed = _parseLogisticsJson(_capturedLogisticsJson.first);
        if (parsed != null && parsed.timelineNodes.isNotEmpty) {
          return parsed;
        }
      }

      // ── DOM 纯文本行状态机兜底（抗接口变动与缓存） ──
      final domText = await _domText(controller);
      if (domText.isNotEmpty) {
        final domNodes = parseJdDomTimeline(domText);
        if (domNodes.isNotEmpty) {
          _logJd('[JD Logistics] DOM fallback parsed ${domNodes.length} nodes for $orderId');
          return _JdLogisticsDetail(
            trackingNumber: '',
            carrier: '京东快递',
            address: '',
            timelineNodes: domNodes,
          );
        }
      }
      return null;
    } catch (e) {
      _logJd('[JD Logistics] fetch error: $e');
      return null;
    }
  }

  Future<String> _domText(WebViewController controller) async {
    try {
      final result = await controller.runJavaScriptReturningResult(
        "(function(){return document.body ? document.body.innerText.slice(0, 30000) : '';})()",
      );
      var text = result.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        try {
          text = jsonDecode(text) as String;
        } catch (_) {
          text = text.substring(1, text.length - 1);
        }
      }
      return text.replaceAll(r'\n', '\n');
    } catch (_) {
      return '';
    }
  }

  /// 解析 get_logistics_list_by_order_m 响应：运单号 + 承运商 + 地址 + 完整轨迹节点
  _JdLogisticsDetail? _parseLogisticsJson(String jsonStr) {
    try {
      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      final body = root['body'] as Map<String, dynamic>?;
      if (body == null) return null;
      final nodes = <Map<String, String>>[];
      final traceList = body['tracePointVOList'] as List<dynamic>?;
      if (traceList != null) {
        for (final t in traceList) {
          if (t is! Map<String, dynamic>) continue;
          // createTime 可能是约定格式或 epoch 毫秒，统一规范化；解析不出时间的节点不写入
          final time = normalizeTraceTime(t['createTime']);
          final text = t['wlStateDesc']?.toString() ?? '';
          if (text.isEmpty || time == null) continue;
          nodes.add({'tag': '', 'time': time, 'text': text});
        }
      }
      if (nodes.isEmpty) return null;
      return _JdLogisticsDetail(
        trackingNumber: body['carriageId']?.toString() ?? '',
        carrier: body['carrier']?.toString() ?? '',
        address: body['recvAddr']?.toString() ?? '',
        timelineNodes: nodes,
      );
    } catch (e) {
      _logJd('[JD Logistics] parse error: $e');
      return null;
    }
  }

  Future<void> _injectNetworkHook(WebViewController controller) async {
    const hookJs = '''
(function(){
  if (window.__jdHookInstalled) return;
  window.__jdHookInstalled = true;

  function report(data){
    try {
      JdBridge.postMessage(typeof data === 'string' ? data : JSON.stringify(data));
    } catch(e) {}
  }

  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function(input, init) {
      var p = origFetch.apply(this, arguments);
      if (p && p.then) {
        p.then(function(res) {
          try {
            res.clone().text().then(function(t) {
              if (t.indexOf('orderList') !== -1 || t.indexOf('tracePointVOList') !== -1 || t.indexOf('carriageId') !== -1) report(t);
            });
          } catch(e) {}
        });
      }
      return p;
    };
  }

  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function() {
    this.addEventListener('load', function() {
      try {
        if (this.responseText && (this.responseText.indexOf('orderList') !== -1 || this.responseText.indexOf('tracePointVOList') !== -1 || this.responseText.indexOf('carriageId') !== -1)) {
          report(this.responseText);
        }
      } catch(e) {}
    });
    return origSend.apply(this, arguments);
  };
})();
''';
    try {
      await controller.runJavaScript(hookJs);
    } catch (_) {}
  }

  Future<void> _injectCookies(String cookies) async {
    final cm = WebViewCookieManager();
    var count = 0;
    for (final part in cookies.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final name = part.substring(0, idx).trim();
      final value = part.substring(idx + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      for (final host in const ['.jd.com', 'trade.m.jd.com', 'home.m.jd.com', 'api.m.jd.com']) {
        try {
          await cm.setCookie(WebViewCookie(domain: host, path: '/', name: name, value: value));
          count++;
        } catch (_) {}
      }
    }
    _logJd('[JD] injected cookie calls: $count');
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

  Future<void> _awaitPageReady() async {
    final controller = _controller;
    if (controller == null) return;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 350));
      try {
        final r = await controller.runJavaScriptReturningResult(
          "(function(){return (document.body && document.body.innerText && document.body.innerText.length > 200 && (document.body.innerText.indexOf('订单') !== -1 || document.body.innerText.indexOf('¥') !== -1)) ? '1' : '0';})()",
        );
        if (r.toString().contains('1')) break;
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 600));
  }

  /// 确保页面处于「购物」分类（排斥秒送外卖，保持全量购物物流流）
  Future<void> _switchToShoppingWaitReceive(WebViewController controller) async {
    const switchJs = '''
(async function(){
  try {
    // 1) 优先点击「购物」分类（避开秒送外卖与生活服务，聚焦电商实物订单）
    var topTabs = document.querySelectorAll('div, span, a, li');
    for (var i = 0; i < topTabs.length; i++) {
      var t = (topTabs[i].innerText || '').trim();
      if (t === '购物' && topTabs[i].offsetParent !== null) {
        topTabs[i].click();
        break;
      }
    }

    await new Promise(r => setTimeout(r, 600));

    // 2) 确保保持在包含在途与最新完成的购物订单流
    // 注意：不点击仅限“待收货”的单向过滤，确保包裹自动收货转入“已完成”后依然能感知更新
    var subTabs = document.querySelectorAll('div, span, a, li, button');
    for (var j = 0; j < subTabs.length; j++) {
      var st = (subTabs[j].innerText || '').trim();
      if (st.indexOf('待使用') === 0 && subTabs[j].offsetParent !== null) {
        // 避开非实物服务类
      }
    }

    await new Promise(r => setTimeout(r, 1000));
  } catch(e) {}
})()
''';
    try {
      await controller.runJavaScript(switchJs);
    } catch (e) {
      _logJd('[JD] switch tab error: $e');
    }
  }

  /// 从拦截到的 order_list_m JSON 响应中解析
  List<_JdOrder> _parseOrdersFromJson(String jsonStr) {
    final list = <_JdOrder>[];
    try {
      var s = jsonStr;
      if (s.startsWith('"') && s.endsWith('"')) {
        s = jsonDecode(s) as String;
      }
      final root = jsonDecode(s) as Map<String, dynamic>;
      final body = root['body'] as Map<String, dynamic>?;
      final orderList = body?['orderList'] as List<dynamic>?;
      if (orderList == null) return list;

      _logJd('[JD Hook] Found ${orderList.length} orders in JSON');

      for (final item in orderList) {
        if (item is! Map<String, dynamic>) continue;

        final orderId = item['orderId']?.toString() ?? '';
        if (orderId.isEmpty) continue;

        if (!isJdCourierDelivery(item)) {
          _logJd('[JD Filter] Not courier delivery, drop: $orderId');
          continue;
        }

        final statusInfo = item['orderStatusInfo'] as Map<String, dynamic>?;
        final statusName = statusInfo?['orderStatusName']?.toString() ?? '';

        // 过滤已关闭/取消
        if (statusName.contains('取消') || statusName.contains('关闭') || statusName.contains('退款')) {
          continue;
        }

        // 正确识别已签收/自动收货（已完成）状态
        final isCompleted = statusName.contains('完成') ||
            statusName.contains('签收') ||
            statusName.contains('妥投') ||
            statusName.contains('已收货');

        // 商品标题与主图
        String goodsName = '';
        String imageUrl = '';
        final wareList = item['wareInfoList'] as List<dynamic>?;
        if (wareList != null && wareList.isNotEmpty) {
          final w0 = wareList[0] as Map<String, dynamic>;
          goodsName = GoodsNameCleaner.clean(w0['wareName']?.toString() ?? '');
          imageUrl = w0['imageUrl']?.toString() ?? '';
          if (imageUrl.startsWith('//')) imageUrl = 'https:$imageUrl';
        }

        // 轨迹进展与自提码
        final prog = item['progressInfo'] as Map<String, dynamic>?;
        final latestText = prog?['content']?.toString() ?? statusName;
        final tip = prog?['tip']?.toString() ?? '';
        final rawProgressLink = prog?['progressLink']?.toString() ?? '';
        final orderDetailLink =
            (item['orderDetailLink'] as Map<String, dynamic>?)?['url']?.toString() ?? '';

        String skuId = '';
        if (wareList != null && wareList.isNotEmpty) {
          final w0 = wareList[0] as Map<String, dynamic>;
          skuId = w0['skuId']?.toString() ?? '';
        }
        final shopInfo = item['shopInfo'] as Map<String, dynamic>?;
        final shopId = shopInfo?['shopId']?.toString() ?? '';
        final dealState = statusInfo?['originOrderStatus']?.toString() ?? '';
        final orderType = item['orderType']?.toString() ?? '';

        final progressLink = buildJdLogisticsUrl(
          orderId: orderId,
          progressLink: rawProgressLink,
          skuId: skuId,
          shopId: shopId,
          dealState: dealState,
          orderType: orderType,
        );

        final pickupCode = _pickupCodeFromText('$latestText $statusName $tip');
        final station = _stationFromText('$latestText $statusName');

        // 若含有提货码/自提码（如已放入快递柜/便民点），即使标记完成也视为待取件；
        // 其余状态统一交由物流状态引擎根据最新轨迹文本推导（与拼多多/淘宝同一套引擎）。
        final status = pickupCode.isNotEmpty
            ? PackageStatus.arrived
            : LogisticsStatusEngine.derive(
                events: [
                  if (latestText.isNotEmpty)
                    {'tag': statusName, 'time': '', 'text': latestText},
                ],
                isPendingShipment: statusName.contains('待发货') ||
                    statusName.contains('等待发货') ||
                    statusName.contains('待出库'),
                isOrderSigned: isCompleted,
                pickupCode: '',
                stationName: station,
              ).status;

        list.add(_JdOrder(
          orderId: orderId,
          status: status,
          statusText: latestText,
          pickupCode: pickupCode,
          stationName: station,
          goodsName: goodsName,
          imageUrl: imageUrl,
          progressLink: progressLink,
          orderDetailLink: orderDetailLink,
        ));
      }
    } catch (e) {
      _logJd('[JD Hook] parse JSON error: $e');
    }
    return list;
  }

  /// DOM 提取兜底脚本 - 深度提取页面中的待收货订单卡片与真实商品图片
  Future<String?> _extractWaitReceiveOrdersViaJs(WebViewController controller) async {
    const jsCode = '''
(function(){
  try {
    var bodyText = document.body ? document.body.innerText : '';
    var goodsImages = [];
    var seenImg = {};

    var imgNodes = document.querySelectorAll('img');
    for (var i = 0; i < imgNodes.length; i++) {
      var src = imgNodes[i].src || imgNodes[i].getAttribute('data-src') || imgNodes[i].getAttribute('data-img') || '';
      if (src.indexOf('//') === 0) src = 'https:' + src;

      // 严格过滤头像、logo、小图标、自营狗标、横幅、Plus会员标志、活动/img/横幅
      var isLogoOrAvatar = src.match(/avatar|logo|icon|plus|member|arrow|banner|badge|dada|mascot|brand|\/img\//i);

      // 京东真实商品主图特征路径（CDN 专属规则：包含 /n0/, /n1/, /n2/, /n5/ 或 popWareMobile）
      var isRealJdProduct = src.match(/popWareMobile|mobile_ware|\/n[0-9]\/|s150x150|s100x100|s200x200|s300x300/i);

      if (src && isRealJdProduct && !isLogoOrAvatar && !seenImg[src]) {
        seenImg[src] = true;
        goodsImages.push(src);
      }
    }

    return JSON.stringify({
      bodyText: bodyText,
      goodsImages: goodsImages
    });
  } catch(e) {
    return JSON.stringify({error: String(e)});
  }
})()
''';
    try {
      final r = await controller.runJavaScriptReturningResult(jsCode);
      if (r == null) return null;
      var s = r.toString();
      if (s == 'null' || s == '""') return null;
      if (s.startsWith('"') && s.endsWith('"')) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is String) {
            s = decoded;
          }
        } catch (_) {
          s = s.substring(1, s.length - 1);
        }
      }
      return s;
    } catch (e) {
      _logJd('[JD] JS extract error: $e');
      return null;
    }
  }

  List<_JdOrder> _parseExtractedOrdersFromDom(String jsonStr) {
    final list = <_JdOrder>[];
    Map<String, dynamic>? root;
    try {
      root = jsonDecode(jsonStr) as Map<String, dynamic>?;
    } catch (e) {
      return list;
    }

    final bodyText = root?['bodyText']?.toString() ?? '';
    final goodsImages = (root?['goodsImages'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    _logJd('[JD Goods Images] count: ${goodsImages.length}, list: $goodsImages');
    if (bodyText.isEmpty) return list;

    final lines = bodyText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    // 匹配包裹在途与近期已签收/完成状态（排除导航 Tab 标签）
    const validOrderStatuses = [
      '正在出库',
      '出库中',
      '等待出库',
      '已出库',
      '派送中',
      '派件中',
      '等待收货',
      '运输中',
      '已到达',
      '已存入',
      '已签收',
      '已妥投',
      '已完成',
      '完成',
    ];

    final seenTitles = <String>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // 排除头部导航区（前 8 行内的误判）
      if (i < 8 && (line == '全部' || line == '待付款' || line == '待收货' || line == '待评价' || line == '下拉刷新')) {
        continue;
      }

      final matchedStatus = validOrderStatuses.firstWhere(
        (st) => line == st || (line.contains(st) && line.length <= 8),
        orElse: () => '',
      );

      if (matchedStatus.isNotEmpty) {
        // 必须在后续行中找到「实付」或「¥」，确保这是一个真实的订单卡片，而非页面散落文本
        var hasOrderContext = false;
        for (var cIdx = i; cIdx < lines.length && cIdx < i + 10; cIdx++) {
          if (lines[cIdx].contains('实付') || lines[cIdx].contains('¥') || lines[cIdx].contains('再次购买')) {
            hasOrderContext = true;
            break;
          }
        }
        if (!hasOrderContext) continue;

        // 提取店铺名称（状态行之前且不是导航标签）
        var shopName = '京东自营';
        if (i > 0) {
          final prev = lines[i - 1];
          if (!prev.contains('全部') && !prev.contains('待付款') && !prev.contains('待收货') && !prev.contains('刷新')) {
            shopName = prev;
          }
        }

        final progress = (i + 1 < lines.length && !lines[i + 1].contains('¥') && !lines[i + 1].startsWith('x'))
            ? lines[i + 1]
            : '';

        var title = '';
        var searchStart = i + (progress.isNotEmpty ? 2 : 1);
        for (var j = searchStart; j < lines.length && j < searchStart + 5; j++) {
          final cand = lines[j];
          if (cand.startsWith('实付') || cand.contains('¥') || cand.contains('再次购买')) {
            break;
          }
          if (cand.length >= 6 && title.isEmpty && !cand.startsWith('x') && !cand.contains('件')) {
            title = cand;
          }
        }

        if (title.isEmpty) {
          title = progress.isNotEmpty ? progress : '京东在途商品';
        }

        if (seenTitles.contains(title)) continue;
        seenTitles.add(title);

        final isCompleted = matchedStatus.contains('签收') ||
            matchedStatus.contains('完成') ||
            matchedStatus.contains('妥投');
        final pickupCode = _pickupCodeFromText('$matchedStatus $progress $title');
        final station = _stationFromText('$shopName $progress');
        final status = pickupCode.isNotEmpty
            ? PackageStatus.arrived
            : (isCompleted
                ? PackageStatus.pickedUp
                : _statusFromText(matchedStatus));
        final hash = md5.convert(utf8.encode('$title$shopName')).toString().substring(0, 12);

        // 匹配商品图片（严格优先选取 /n1/, /n2/, /n0/, /popWareMobile/ 等商品路径）
        final realProductImgs = goodsImages.where((url) =>
            url.contains('/n1/') ||
            url.contains('/n2/') ||
            url.contains('/n0/') ||
            url.contains('/n5/') ||
            url.contains('/popWareMobile/')).toList();
        final img = realProductImgs.isNotEmpty
            ? realProductImgs.first
            : (goodsImages.isNotEmpty ? goodsImages.first : '');

        _logJd('[JD Found In-Transit] Title: $title, Status: ${status.label}, Progress: $progress');

        list.add(_JdOrder(
          orderId: hash,
          status: status,
          statusText: progress.isNotEmpty ? '$matchedStatus · $progress' : matchedStatus,
          pickupCode: pickupCode,
          stationName: station.isNotEmpty ? station : shopName,
          goodsName: GoodsNameCleaner.clean(title),
          imageUrl: img,
        ));
      }
    }

    return list;
  }

  PackageStatus _statusFromText(String block) {
    if (block.contains('已签收') || block.contains('已完成') || block.contains('妥投')) {
      return PackageStatus.pickedUp;
    }
    if (block.contains('待发货') || block.contains('等待发货') || block.contains('待出库')) {
      return PackageStatus.pendingShipment;
    }
    if (block.contains('待取件') || block.contains('待自提') || block.contains('已到达') ||
        block.contains('已存入')) {
      return PackageStatus.arrived;
    }
    if (block.contains('派送中') || block.contains('派件') || block.contains('送货中')) {
      return PackageStatus.delivering;
    }
    return PackageStatus.transit;
  }

  String _statusTextFromText(String block) {
    if (block.contains('待收货') || block.contains('等待收货')) return '等待收货';
    if (block.contains('派送中')) return '派送中';
    if (block.contains('已存入')) return '已存入自提柜';
    return '运输中';
  }

  String _pickupCodeFromText(String block) {
    final m = RegExp(r'(?:取件码|提货码|取货码|凭码|自提码)[:：\s]*([A-Za-z0-9\-]{3,12})').firstMatch(block);
    return m?.group(1) ?? '';
  }

  String _stationFromText(String block) {
    final m = RegExp(r'([\u4e00-\u9fa5A-Za-z0-9（）()]{2,24}(?:驿站|快递柜|自提柜|自提点|代收点|服务点|超市))').firstMatch(block);
    return m?.group(1) ?? '';
  }

  String _goodsFromText(String block) {
    for (final raw in block.split('\n')) {
      final line = raw.trim();
      if (line.length < 4) continue;
      if (line.contains('订单号') || line.contains('订单编号') || line.contains('实付')) continue;
      if (line.contains('共') && line.contains('件')) continue;
      if (line.contains('再次购买') || line.contains('查看物流') || line.contains('去支付') || line.contains('退换')) continue;
      if (line.contains('我要催单') || line.contains('申请退款') || line.contains('正在出库') || line.contains('准备出库')) continue;
      if (line.endsWith('旗舰店') || line.endsWith('专卖店') || line.endsWith('专营店') || line.endsWith('自营店')) continue;
      if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(line)) continue;
      if (RegExp(r'^[0-9\s\-\:]+$').hasMatch(line)) continue;
      return line.length > 50 ? line.substring(0, 50) : line;
    }
    return '';
  }
}

class _JdOrder {
  final String orderId;
  final PackageStatus status;
  final String statusText;
  final String pickupCode;
  final String stationName;
  final String goodsName;
  final String imageUrl;
  final String progressLink;
  final String orderDetailLink;

  const _JdOrder({
    required this.orderId,
    required this.status,
    required this.statusText,
    required this.pickupCode,
    required this.stationName,
    required this.goodsName,
    required this.imageUrl,
    this.progressLink = '',
    this.orderDetailLink = '',
  });
}

/// 京东物流跟踪页解析结果：真实运单号 + 承运商 + 收货地址 + 完整轨迹节点
class _JdLogisticsDetail {
  final String trackingNumber;
  final String carrier;
  final String address;
  final List<Map<String, String>> timelineNodes;

  const _JdLogisticsDetail({
    required this.trackingNumber,
    required this.carrier,
    required this.address,
    required this.timelineNodes,
  });
}
