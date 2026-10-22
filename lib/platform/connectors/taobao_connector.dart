/// 淘宝/菜鸟 H5与SSR真实连接器
library;

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/engine/logistics_status_engine.dart';
import '../../core/models/package.dart';
import '../../core/models/package_status.dart';
import '../../core/parser/taobao_trace_parser.dart';
import '../../core/sanitizer/goods_name_cleaner.dart';
import '../storage/platform_auth_store.dart';
import '../sync/sync_history_manager.dart';
import '../webview/platform_cookie.dart';
import 'platform_connector.dart';
import 'taobao_sync_rules.dart';
import 'concurrent_limiter.dart';
import 'sync_optimizer.dart';

void _logTb(String msg) {
  debugPrint(msg);
}

class _CainiaoItem {
  final String pickupCode;
  final String trackingNumber;
  final String stationName;
  final String courier;

  const _CainiaoItem({
    required this.pickupCode,
    required this.trackingNumber,
    required this.stationName,
    required this.courier,
  });
}

class TaobaoH5Connector implements PlatformConnector {
  final PlatformAuthStore _authStore;
  final List<String> Function()? _getActiveTrackingNumbers;
  final List<Package> Function()? _getLocalPackages;
  /// 本次同步是否忽略「24 小时内已同步」跳过，由用户主动触发的强制重拉置位
  final bool Function()? _shouldForceRefetch;
  final SyncHistoryManager _syncHistory = SyncHistoryManager();
  static const _appKey = '12574478';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  TaobaoH5Connector({
    PlatformAuthStore? authStore,
    List<String> Function()? getActiveTrackingNumbers,
    List<Package> Function()? getLocalPackages,
    bool Function()? shouldForceRefetch,
  })  : _authStore = authStore ?? PlatformAuthStore(),
        _getActiveTrackingNumbers = getActiveTrackingNumbers,
        _getLocalPackages = getLocalPackages,
        _shouldForceRefetch = shouldForceRefetch;

  @override
  String get platformId => 'taobao';

  @override
  String get displayName => '淘宝 / 天猫';

  @override
  String get brandColorHex => '#FF5000';

  @override
  Future<bool> isAuthenticated() async => _authStore.isBound('taobao');

  bool _cancelled = false;

  @override
  Future<void> cancelSync() async {
    _cancelled = true;
    _cainiaoController = null;
  }

  String? _lastIssue;

  @override
  String? get lastIssue => _lastIssue;

  /// 用户重新授权后清理上一次的失效提示
  void clearLastIssue() {
    _lastIssue = null;
  }

  WebViewController? _cainiaoController;
  final List<String> _capturedCainiaoJson = [];

  @override
  Stream<Package> streamSync() async* {
    _cancelled = false;
    _lastIssue = null;
    final cookies = _authStore.getCookies('taobao');
    if (cookies == null || cookies.trim().isEmpty) return;

    _logTb('[Taobao] Starting sync with cookies (len: ${cookies.length})');

    // ── 阶段 1：直连淘宝内嵌菜鸟驿站（Cainiao Station）抓取待取件包裹与真实货架码 ──
    // 本次同步菜鸟列表里的包裹，阶段 2 用来「以菜鸟为准」（淘宝已签收但驿站还挂着）
    final cainiaoPackages = <Package>[];
    try {
      final cainiaoItems = await _fetchCainiaoStationPackages(cookies);
      if (_cancelled) return;
      // 日志只记数量，不打印运单号、取件码、驿站名
      _logTb('[Cainiao] 阶段 1 产出待取件包裹 ${cainiaoItems.length} 个');
      for (final item in cainiaoItems) {
        if (_cancelled) return;
        final cn = Package(
          id: 'CN_${item.trackingNumber}',
          trackingNumber: item.trackingNumber,
          courier: _resolveCourier(item.courier),
          goodsName: '快递包裹',
          stationName: item.stationName.isNotEmpty ? item.stationName : '菜鸟驿站',
          pickupCode: item.pickupCode,
          location: item.stationName,
          platform: 'cainiao',
          urgency: UrgencyLevel.urgent,
          status: PackageStatus.arrived,
          addedAt: DateTime.now(),
        );
        cainiaoPackages.add(cn);
        yield cn;
      }
    } catch (e) {
      _logTb('[Cainiao] 阶段 1 异常：${e.runtimeType}');
    }

    if (_cancelled) return;

    // ── 阶段 2：淘宝已买到的宝贝订单列表与在途物流 ──
    final client = http.Client();
    try {
      // 1. 获取买家最近订单列表
      final orders = await _fetchBoughtOrders(client, cookies);
      // 2. 只对订单列表里有「查看物流」按钮的订单请求 SSR 物流详情；
      //    饿了么等订单（bizType 5000）没有这个按钮，请求详情只会返回 JUMP_302
      final withLogistics = orders.where((o) => o.hasLogistics).toList();
      _logTb('[Taobao] 订单 ${orders.length} 个，有「查看物流」${withLogistics.length} 个，'
          '跳过 ${orders.length - withLogistics.length} 个');

      // 已签收订单只请求一次：本地已有、已签收且轨迹不为空的跳过（不另存标记）
      final local = _getLocalPackages?.call() ?? const <Package>[];
      final force = _shouldForceRefetch?.call() ?? false;

      // ⚡ 优化：智能跳过最近已同步的订单（24小时内）；强制重拉时忽略该窗口
      final needFetchOrders = SyncOptimizer.filterNeedsFetch<_TbOrder>(
        orders: withLogistics,
        localPackages: local,
        getOrderId: (order) => order.orderId,
        getStatus: (order) => PackageStatus.transit, // 从订单列表无法准确判断状态，默认在途
        recentThreshold: const Duration(hours: 24),
        force: force,
      );

      // 保留旧的已签收跳过逻辑（作为额外的过滤）
      final finalNeedFetch = <_TbOrder>[];
      var skippedSigned = 0;
      for (final order in needFetchOrders) {
        final localPkg = findLocalTaobaoPackage(local, order.orderId);
        if (shouldSkipSignedDetail(localPkg)) {
          skippedSigned++;
          continue;
        }
        finalNeedFetch.add(order);
      }

      _logTb('[Taobao] 智能跳过（24h内已同步）${withLogistics.length - needFetchOrders.length} 个，'
          '已签收且本地有轨迹跳过 $skippedSigned 个，需拉取详情 ${finalNeedFetch.length} 个');

      // ⚡ 优化：并发拉取订单详情（限制并发数为 3）
      final executor = ThrottledExecutor(
        maxConcurrent: 3,
        minDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(milliseconds: 300),
      );

      final detailTasks = needFetchOrders.map((order) {
        return () => _fetchSsrLogistics(client, cookies, order.orderId).then((parcel) {
          return {'order': order, 'parcel': parcel};
        });
      }).toList();

      final results = await executor.executeAll(detailTasks);

      var parsedCount = 0;
      var failedCount = 0;
      var cainiaoOverrides = 0;

      for (final result in results) {
        if (_cancelled) break;

        final order = result['order'] as _TbOrder;
        final parcel = result['parcel'] as _TbParcel?;

        if (parcel == null) {
          failedCount++;
        } else {
          parsedCount++;
          final status = parcel.derivedStatus ?? _resolveStatus(parcel.stateLabel);
          final tbPkg = Package(
            id: taobaoPackageId(order.orderId),
            trackingNumber: parcel.mailNo.isNotEmpty ? parcel.mailNo : order.orderId,
            courier: _resolveCourier(parcel.cpName),
            goodsName: order.goodsName,
            goodsImageUrl: order.goodsPic,
            pickupCode: parcel.pickupCode,
            stationName: parcel.stationName.isNotEmpty ? parcel.stationName : '菜鸟驿站',
            location: parcel.location,
            platform: 'taobao',
            // 急件由引擎统一判定：已签收时即使轨迹里有旧取件码也不标急件
            urgency: LogisticsStatusEngine.urgencyFor(status: status, pickupCode: parcel.pickupCode),
            status: status,
            addedAt: DateTime.now(),
            rawTimelineJson: parcel.rawTimelineJson,
          );
          // 淘宝已签收但菜鸟驿站还挂着且有取件码 → 以菜鸟为准（用户手动已取 / 归档的不改）
          final localPkg = findLocalTaobaoPackage(local, order.orderId);
          final finalPkg = applyCainiaoPriority(tbPkg, cainiaoPackages, local: localPkg);
          if (!identical(finalPkg, tbPkg)) cainiaoOverrides++;
          yield finalPkg;
        }
      }

      _logTb('[Taobao] 物流详情（并发拉取）：已签收且本地有轨迹跳过 $skippedSigned 个，'
          '请求 ${parsedCount + failedCount} 个，解析成功 $parsedCount 个，失败 $failedCount 个，'
          '已签收但菜鸟仍待取改回待取件 $cainiaoOverrides 个');

      // ── 阶段 3：针对待取件但取件码仍为后5位或空的包裹，以运单号定向查询菜鸟货架码 ──
      if (_getActiveTrackingNumbers != null) {
        try {
          final activeTns = _getActiveTrackingNumbers();
          // 打码单号（含 *）查不到菜鸟，直接跳过
          final pendingTns = queryableTrackingNumbers(activeTns);
          var targetedHits = 0;
          for (final tn in pendingTns) {
            if (_cancelled) break;
            final item = await _queryCainiaoByMailNo(client, cookies, tn);
            if (item != null && item.pickupCode.isNotEmpty) {
              targetedHits++;
              yield Package(
                id: 'CN_$tn',
                trackingNumber: tn,
                courier: _resolveCourier(item.courier),
                goodsName: '快递包裹',
                stationName: item.stationName.isNotEmpty ? item.stationName : '菜鸟驿站',
                pickupCode: item.pickupCode,
                location: item.stationName,
                platform: 'cainiao',
                urgency: UrgencyLevel.urgent,
                status: PackageStatus.arrived,
                addedAt: DateTime.now(),
              );
            }
          }
          _logTb('[Cainiao] 阶段 3 按运单号查货架码：跳过打码单号 ${activeTns.length - pendingTns.length} 个，'
              '查询 ${pendingTns.length} 个，拿到取件码 $targetedHits 个');
        } catch (e) {
          _logTb('[Cainiao] 阶段 3 异常：${e.runtimeType}');
        }

        // 直连菜鸟驿站官方多包裹接口（复刻前端页面自身请求），一次性拿到全部到站包裹的取件码
        try {
          final listItems = await _queryCainiaoStationList(client, cookies);
          final usable = listItems.where((i) => i.pickupCode.isNotEmpty && i.trackingNumber.isNotEmpty).length;
          _logTb('[Cainiao StationList] 返回 ${listItems.length} 个，带取件码和运单号 $usable 个');
          for (final item in listItems) {
            if (_cancelled) break;
            if (item.pickupCode.isEmpty || item.trackingNumber.isEmpty) continue;
            yield Package(
              id: 'CN_${item.trackingNumber}',
              trackingNumber: item.trackingNumber,
              courier: _resolveCourier(item.courier),
              goodsName: '快递包裹',
              stationName: item.stationName.isNotEmpty ? item.stationName : '菜鸟驿站',
              pickupCode: item.pickupCode,
              location: item.stationName,
              platform: 'cainiao',
              urgency: UrgencyLevel.urgent,
              status: PackageStatus.arrived,
              addedAt: DateTime.now(),
            );
          }
        } catch (e) {
          _logTb('[Cainiao] StationList 异常：${e.runtimeType}');
        }
      }
    } catch (e) {
      // 网络/解析异常容错；只记异常类型，异常文本可能带请求 URL（含订单号）
      _logTb('[Taobao] Stage 2/3 中断：${e.runtimeType}');
    } finally {
      client.close();
    }
  }

  /// 调用菜鸟驿站官方「多站点包裹列表」接口（mtop.cainiao.pickup.plus.queryMultiStaPackages4Xy）
  Future<List<_CainiaoItem>> _queryCainiaoStationList(http.Client client, String cookies) async {
    final items = <_CainiaoItem>[];
    try {
      final traceId = '${DateTime.now().millisecondsSinceEpoch}-x${DateTime.now().microsecond % 100000}';
      final dataObj = {
        'stationType': 'XY',
        'source': '',
        'traceId': traceId,
        'pageNo': 1,
        'pageSize': 30,
      };
      final rawJson = await _mtopCall(
        client,
        cookies,
        api: 'mtop.cainiao.pickup.plus.queryMultiStaPackages4Xy',
        v: '1.0',
        dataRaw: jsonEncode(dataObj),
      );
      if (rawJson == null || rawJson.isEmpty) return items;

      final s = stripJsonp(rawJson);
      final root = jsonDecode(s) as Map<String, dynamic>;
      _logTb('[Cainiao StationList RET] ${root['ret']} len=${rawJson.length}');

      // 原「紧凑诊断」会把运单号、取件码、驿站名逐个打进日志，已删除；字段定位改用 P11-a 的脱敏采集

      // 提取 运单号 + 取件码 组合
      final shelfReg = RegExp(r'^\d{1,3}-\d{1,3}-\d{2,5}$');
      const codeKeys = [
        'takeCode', 'fetchCode', 'pickupCode', 'shelfCode', 'pickCode',
        'pickupNo', 'takeNo', 'fetchNo', 'codeValue', 'pickupCodeText',
      ];
      const mailKeys = ['mailNo', 'waybillNo', 'trackingNo', 'trackingNumber', 'mailno'];

      void walk(dynamic node) {
        if (node is Map) {
          final m = node.cast<String, dynamic>();
          var mail = '';
          var code = '';
          for (final k in mailKeys) {
            final v = m[k]?.toString().trim() ?? '';
            if (v.length >= 10) {
              mail = v;
              break;
            }
          }
          for (final k in codeKeys) {
            final v = m[k]?.toString().trim() ?? '';
            if (v.isNotEmpty && (shelfReg.hasMatch(v) || v.length <= 12)) {
              if (code.isEmpty || (shelfReg.hasMatch(v) && !shelfReg.hasMatch(code))) code = v;
            }
          }
          if (mail.isNotEmpty && code.isNotEmpty) {
            final st = (m['stationName'] ?? m['siteName'] ?? '').toString().trim();
            final cp = (m['cpName'] ?? m['expressCompanyName'] ?? m['cpCode'] ?? '').toString().trim();
            items.add(_CainiaoItem(
              pickupCode: code,
              trackingNumber: mail,
              stationName: st,
              courier: cp,
            ));
          }
          for (final v in m.values) {
            walk(v);
          }
        } else if (node is List) {
          for (final item in node) {
            walk(item);
          }
        }
      }
      walk(root);
    } catch (e) {
      _logTb('[Cainiao StationList] 解析异常：${e.runtimeType}');
    }
    return items;
  }

  /// 注入网络拦截钩子，抓取淘宝菜鸟驿站核心接口 mtop.cainiao.pickup.plus.queryMultiStaPackages4Xy
  Future<void> _injectCainiaoNetworkHook(WebViewController controller) async {
    const hookJs = '''
(function(){
  if (window.__cnHookInstalled) return;
  window.__cnHookInstalled = true;

  function report(data){
    try {
      CainiaoBridge.postMessage(typeof data === 'string' ? data : JSON.stringify(data));
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
              if (t.indexOf('Package') !== -1 || t.indexOf('mailNo') !== -1 || t.indexOf('fetchCode') !== -1 || t.indexOf('pickup') !== -1 || t.indexOf('takeCode') !== -1) {
                report(t);
              }
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
        if (this.responseText && (this.responseText.indexOf('Package') !== -1 || this.responseText.indexOf('mailNo') !== -1 || this.responseText.indexOf('fetchCode') !== -1 || this.responseText.indexOf('takeCode') !== -1)) {
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

  /// 在本地安全浏览器上下文中加载淘宝官方菜鸟驿站模块，提取待取件货架码与运单号
  Future<List<_CainiaoItem>> _fetchCainiaoStationPackages(String cookies) async {
    final list = <_CainiaoItem>[];
    _capturedCainiaoJson.clear();

    // ① 先在 Dart 侧发起一次轻量 mtop 调用，主动触发 _m_h5_tk 令牌轮换并落盘，
    //    避免菜鸟页面因内嵌令牌过期而误报「Session过期」，从而拿不到取件码。
    var effectiveCookies = cookies;
    try {
      final tmpClient = http.Client();
      await _mtopCall(
        tmpClient,
        cookies,
        api: 'mtop.cainiao.pickup.search.getTimeStamp',
        v: '1.0',
        dataRaw: jsonEncode({
          'stationType': 'XY',
          'source': '',
          'traceId': '${DateTime.now().millisecondsSinceEpoch}-tok',
        }),
      );
      tmpClient.close();
      final refreshed = _authStore.getCookies('taobao');
      if (refreshed != null && refreshed.isNotEmpty) {
        effectiveCookies = refreshed;
      }
    } catch (_) {}

    try {
      // 原生注入，保留 HttpOnly/Secure，避免把会话令牌降级为页面脚本可读
      await injectCookieString(
        cookies: effectiveCookies,
        domains: const [
          '.taobao.com',
          'h5api.m.taobao.com',
          'pages-fast.m.taobao.com',
          'main.m.taobao.com',
          '.cainiao.com',
          'page.cainiao.com',
        ],
      );

      final WebViewController controller;
      if (_cainiaoController != null) {
        controller = _cainiaoController!;
      } else {
        controller = WebViewController();
        _cainiaoController = controller;
        controller
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setUserAgent(_ua)
          ..addJavaScriptChannel(
            'CainiaoBridge',
            onMessageReceived: (JavaScriptMessage msg) {
              final text = msg.message;
              if (text.contains('Package') || text.contains('mailNo') || text.contains('fetchCode') || text.contains('takeCode')) {
                _logTb('[Cainiao Hook] Captured JSON len: ${text.length}');
                _capturedCainiaoJson.add(text);
              }
            },
          )
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageStarted: (url) {
                _injectCainiaoNetworkHook(controller);
              },
              onNavigationRequest: (request) {
                final lower = request.url.toLowerCase();
                if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
                  return NavigationDecision.prevent;
                }
                return NavigationDecision.navigate;
              },
            ),
          );
      }

      // 淘宝官方末端菜鸟驿站前端地址（直接复刻手机淘宝首页「菜鸟驿站」模块）
      const cainiaoUrl = 'https://pages-fast.m.taobao.com/wow/z/uniapp/1100333/last-mile-fe/m-end-school-tab/home';
      _logTb('[Cainiao] Loading Taobao last-mile Cainiao page...');
      await controller.loadRequest(Uri.parse(cainiaoUrl));
      await _injectCainiaoNetworkHook(controller);

      // 轮询等待页面渲染或接口返回（必须等待真实的货架取件码出现，严防骨架屏抢跑）
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        if (_cancelled) break;
        await Future.delayed(const Duration(milliseconds: 150));
        if (_capturedCainiaoJson.isNotEmpty) break;
        try {
          final r = await controller.runJavaScriptReturningResult(
            "(function(){ if (!document.body || !document.body.innerText) return '0'; var t = document.body.innerText; return /\\d{1,3}-\\d{1,3}-\\d{2,5}/.test(t) ? '1' : '0'; })()",
          );
          if (r.toString().contains('1')) {
            // 检测到首个货架码后，缓冲 350ms 确保页面全部卡片（中通/邮政/圆通）完整进入 DOM
            await Future.delayed(const Duration(milliseconds: 350));
            break;
          }
        } catch (_) {}
      }

      try {
        final landedHref = await controller.runJavaScriptReturningResult('location.href');
        // 只记域名和路径：跳转登录等页面的查询串里可能带用户标识或令牌
        final landed = Uri.tryParse(landedHref.toString().replaceAll('"', ''));
        _logTb('[Cainiao Landed] ${landed == null ? '-' : '${landed.host}${landed.path}'}');
        final title = await controller.runJavaScriptReturningResult('document.title');
        _logTb('[Cainiao Title] $title');
      } catch (e) {
        _logTb('[Cainiao Debug Err] ${e.runtimeType}');
      }

      // 触发可能折叠的“还有包裹未显示？查询取件码”展开交互，让隐藏的包裹（如圆通等）进入 DOM
      try {
        await controller.runJavaScript('''
(function(){
  try {
    var all = document.querySelectorAll('div,span,a,p,button');
    for (var i = 0; i < all.length; i++) {
      var t = (all[i].innerText || '').trim();
      if (t.indexOf('还有包裹未显示') !== -1 || t.indexOf('查询取件码') !== -1 || t === '查看全部' || t === '展开') {
        all[i].click();
      }
    }
  } catch(e) {}
})();
''');
        await Future.delayed(const Duration(milliseconds: 350));
      } catch (_) {}

      // 1) 优先解析网络钩子截获的官方多包裹接口响应
      if (_capturedCainiaoJson.isNotEmpty) {
        for (final jsonStr in _capturedCainiaoJson) {
          list.addAll(_parseCainiaoJson(jsonStr));
        }
      }

      // 2) DOM 智能提取（无论快递公司名称带“速递”还是“快递”，均精准提取货架码与单号）
      const jsExtractor = '''
(function(){
  try {
    var bodyText = document.body ? document.body.innerText : '';
    var items = [];
    var lines = bodyText.split('\\n').map(function(l){ return l.trim(); }).filter(function(l){ return l.length > 0; });

    // 匹配如 16-1-7002, 9-4-1006 等货架取件码（允许行内带“取件码”或“今日到站”等修饰）
    var codeRegex = /(?:取件码|提货码|取货码)?\\s*([0-9]{1,3}-[0-9]{1,3}-[0-9]{2,5})/;
    // 匹配运单号（字母前缀单号如 YT0712583482621、JT553... 或 10-22 位纯数字单号）
    var trackRegex = /([A-Za-z]{2,5}\\d{8,20}|\\d{10,22})/;

    for (var i = 0; i < lines.length; i++) {
      var l = lines[i];
      var cm = l.match(codeRegex);
      if (cm) {
        var pickupCode = cm[1];
        var trackingNo = '';
        var courier = '';
        var station = '';

        // 双向检索：向下 1~8 行，或向上 1~4 行找运单号
        for (var j = i + 1; j < lines.length && j <= i + 8; j++) {
          var lineJ = lines[j];
          var tm = lineJ.match(trackRegex);
          if (tm && tm[1] !== pickupCode) {
            trackingNo = tm[1];
            if (lineJ.indexOf('邮政') !== -1 || lineJ.indexOf('EMS') !== -1) courier = 'ems';
            else if (lineJ.indexOf('顺丰') !== -1) courier = 'sf';
            else if (lineJ.indexOf('极兔') !== -1) courier = 'jt';
            else if (lineJ.indexOf('圆通') !== -1) courier = 'yt';
            else if (lineJ.indexOf('中通') !== -1) courier = 'zto';
            else if (lineJ.indexOf('申通') !== -1) courier = 'sto';
            else if (lineJ.indexOf('韵达') !== -1) courier = 'yd';
            else if (trackingNo.startsWith('YT')) courier = 'yt';
            else if (trackingNo.startsWith('JT')) courier = 'jt';
            else if (trackingNo.startsWith('SF')) courier = 'sf';
            break;
          }
        }

        if (!trackingNo) {
          for (var j = i - 1; j >= 0 && j >= i - 4; j--) {
            var lineJ = lines[j];
            var tm = lineJ.match(trackRegex);
            if (tm && tm[1] !== pickupCode) {
              trackingNo = tm[1];
              if (trackingNo.startsWith('YT') || lineJ.indexOf('圆通') !== -1) courier = 'yt';
              else if (trackingNo.startsWith('JT') || lineJ.indexOf('极兔') !== -1) courier = 'jt';
              else if (trackingNo.startsWith('SF') || lineJ.indexOf('顺丰') !== -1) courier = 'sf';
              break;
            }
          }
        }

        // 向上检索 1~8 行找驿站名称
        for (var k = i - 1; k >= 0 && k >= i - 8; k--) {
          var sm = lines[k].match(/([\\u4e00-\\u9fa5A-Za-z0-9]{2,24}(?:驿站|门店|店|代收点|北门店|南门店|东门店|西门店|自提点))/);
          if (sm && sm[1].indexOf('看包裹') === -1 && sm[1].indexOf('寄快递') === -1) {
            station = sm[1];
            break;
          }
        }

        if (trackingNo.length >= 10) {
          items.push({
            pickupCode: pickupCode,
            trackingNumber: trackingNo,
            courier: courier,
            stationName: station
          });
        }
      }
    }

    return JSON.stringify({
      itemCount: items.length,
      items: items,
      snippet: bodyText.slice(0, 600)
    });
  } catch(e) {
    return JSON.stringify({ error: String(e) });
  }
})()
''';

      if (_cancelled) return list;

      final res = await controller.runJavaScriptReturningResult(jsExtractor);
      if (_cancelled) return list;
      var s = res.toString();
      if (s.startsWith('"') && s.endsWith('"')) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is String) s = decoded;
        } catch (_) {}
      }

      // 若检测到 Session过期 或 需要登录，在淘宝主站快速预热握手并重试一次
      if (s.contains('Session过期') || s.contains('您需要登录才能继续访问')) {
        _logTb('[Cainiao] Session expired detected, attempting silent refresh via main.m.taobao.com...');
        await controller.loadRequest(Uri.parse('https://main.m.taobao.com/'));
        await Future.delayed(const Duration(milliseconds: 900));
        await controller.loadRequest(Uri.parse(cainiaoUrl));
        await _injectCainiaoNetworkHook(controller);

        final retryDeadline = DateTime.now().add(const Duration(seconds: 4));
        while (DateTime.now().isBefore(retryDeadline)) {
          if (_cancelled) break;
          await Future.delayed(const Duration(milliseconds: 150));
          try {
            final r = await controller.runJavaScriptReturningResult(
              "(function(){ if (!document.body || !document.body.innerText) return '0'; var t = document.body.innerText; return /\\d{1,3}-\\d{1,3}-\\d{2,5}/.test(t) ? '1' : '0'; })()",
            );
            if (r.toString().contains('1')) {
              await Future.delayed(const Duration(milliseconds: 350));
              break;
            }
          } catch (_) {}
        }
        final retryRes = await controller.runJavaScriptReturningResult(jsExtractor);
        var retryS = retryRes.toString();
        if (retryS.startsWith('"') && retryS.endsWith('"')) {
          try {
            final decoded = jsonDecode(retryS);
            if (decoded is String) retryS = decoded;
          } catch (_) {}
        }
        s = retryS;
        if (s.contains('Session过期') || s.contains('您需要登录才能继续访问')) {
          await _markSessionExpired();
        }
      }

      // 注意：此处不再把 WebView 中的 Cookie 回写到存储。
      // WebView 会话可能被阿里风控重置（Set-Cookie: cookie2=deleted 等），
      // 一旦回写会永久破坏存储中的登录态；登录凭据只由用户主动授权时更新。
      // _m_h5_tk 令牌的轮换在 _mtopCall 中就地更新，不触碰登录会话字段。

      final root = jsonDecode(s) as Map<String, dynamic>?;
      final rawItems = root?['items'] as List<dynamic>?;
      _logTb('[Cainiao DOM Extract] items=${root?['itemCount'] ?? rawItems?.length ?? 0} len=${s.length}');
      // 页面成功渲染出包裹数据 → 登录态健康，清除此前的失效标记
      if (rawItems != null && rawItems.isNotEmpty && _lastIssue == null) {
        await _authStore.setExpired('taobao', false);
      }
      if (rawItems != null) {
        for (final it in rawItems) {
          if (it is! Map<String, dynamic>) continue;
          final code = it['pickupCode']?.toString() ?? '';
          final track = it['trackingNumber']?.toString() ?? '';
          final st = it['stationName']?.toString() ?? '';
          final cr = it['courier']?.toString() ?? '';
          if (code.isNotEmpty && track.isNotEmpty) {
            list.add(_CainiaoItem(
              pickupCode: code,
              trackingNumber: track,
              stationName: st,
              courier: cr,
            ));
          }
        }
      }

      // 按运单号唯一去重
      final uniqueMap = <String, _CainiaoItem>{};
      for (final it in list) {
        uniqueMap[it.trackingNumber] = it;
      }
      _logTb('[Cainiao] Final station pickup packages: ${uniqueMap.length}');
      return uniqueMap.values.toList();
    } catch (e) {
      _logTb('[Cainiao] fetch error: ${e.runtimeType}');
      return list;
    }
  }

  /// 递归解析菜鸟多站点包裹接口返回的 JSON（支持兼容 JSONP 包装）
  List<_CainiaoItem> _parseCainiaoJson(String jsonStr) {
    final list = <_CainiaoItem>[];
    try {
      final s = stripJsonp(jsonStr);
      final root = jsonDecode(s);
      void walk(dynamic node) {
        if (node is Map) {
          final m = node.cast<String, dynamic>();
          final mailNo = (m['mailNo'] ?? m['waybillNo'] ?? m['trackingNo'] ?? m['trackingNumber'])?.toString().trim() ?? '';
          final code = (m['takeCode'] ?? m['fetchCode'] ?? m['pickupCode'] ?? m['fetchNum'] ?? m['shelfCode'])?.toString().trim() ?? '';
          final station = (m['stationName'] ?? m['siteName'] ?? m['stationDesc'] ?? m['station'])?.toString().trim() ?? '';
          final cp = (m['cpName'] ?? m['expressCompanyName'] ?? m['cpCode'])?.toString().trim() ?? '';

          if (mailNo.length >= 10 && code.isNotEmpty) {
            list.add(_CainiaoItem(
              pickupCode: code,
              trackingNumber: mailNo,
              stationName: station,
              courier: cp,
            ));
          }
          for (final val in m.values) {
            walk(val);
          }
        } else if (node is List) {
          for (final item in node) {
            walk(item);
          }
        }
      }
      walk(root);
    } catch (e) {
      _logTb('[Cainiao Hook Parse Err] ${e.runtimeType}');
    }
    return list;
  }

  Future<List<_TbOrder>> _fetchBoughtOrders(http.Client client, String cookies) async {
    final dataObj = {
      'tabCode': 'all',
      'page': 1,
      'OrderType': 'OrderList',
      'templateConfigVersion': '0',
      'appName': 'tborder',
      'appVersion': '3.0',
      'condition': '{"version":"1.0.0","appChannel":""}',
      'ttid': '201200@taobao_h5_9.18.0',
      'requestIdentity': '#t#ip#h5',
    };

    final rawJson = await _mtopCall(
      client,
      cookies,
      api: 'mtop.taobao.order.queryboughtlistv2',
      v: '1.0',
      dataRaw: jsonEncode(dataObj),
    );

    if (rawJson == null) return [];

    final orders = <_TbOrder>[];
    try {
      final jsonStr = stripJsonp(rawJson);
      final root = jsonDecode(jsonStr) as Map<String, dynamic>;
      final data = root['data'] as Map<String, dynamic>?;
      if (data == null) return [];

      dynamic inner = data['data'];
      if (data['result'] != null && data['result'] is String) {
        try {
          inner = jsonDecode(data['result'] as String);
        } catch (_) {}
      }

      if (inner is Map<String, dynamic>) {
        final mainOrders = inner['mainOrders'] as List<dynamic>?;
        if (mainOrders != null) {
          for (final o in mainOrders) {
            final orderMap = o as Map<String, dynamic>;
            final id = orderMap['id']?.toString() ?? '';
            final statusInfo = orderMap['statusInfo'] as Map<String, dynamic>?;
            final statusText = statusInfo?['text']?.toString() ?? '';

            // 过滤关闭、退款订单
            if (statusText.contains('关闭') || statusText.contains('退款')) continue;

            String title = '';
            String pic = '';
            final subOrders = orderMap['subOrders'] as List<dynamic>?;
            if (subOrders != null && subOrders.isNotEmpty) {
              final sub = subOrders[0] as Map<String, dynamic>;
              final itemInfo = sub['itemInfo'] as Map<String, dynamic>?;
              title = GoodsNameCleaner.clean(itemInfo?['title']?.toString() ?? '');
              pic = itemInfo?['pic']?.toString() ?? '';
              // 淘宝返回协议相对 URL（//img.alicdn.com/...），不补 scheme 会导致 Image.network 加载失败
              if (pic.startsWith('//')) pic = 'https:$pic';
            }

            orders.add(_TbOrder(
              orderId: id,
              statusText: statusText,
              goodsName: title,
              goodsPic: pic,
              hasLogistics: TaobaoTraceParser.orderHasLogistics(orderMap),
            ));
          }
        }
      } else {
        _logTb('[Taobao] 订单列表没有 mainOrders 结构');
      }
    } catch (e) {
      _logTb('[Taobao] 订单列表解析失败：${e.runtimeType}（已解析 ${orders.length} 个）');
    }
    return orders;
  }

  /// 请求物流详情 SSR 页并交给 [TaobaoTraceParser] 解析。
  ///
  /// 每个返回 null 的分支都打一行原因日志（只记步骤、原因和数量，不记订单号/运单号/Cookie）。
  Future<_TbParcel?> _fetchSsrLogistics(http.Client client, String cookies, String orderId) async {
    try {
      final url = 'https://pages-g.m.taobao.com/wow/z/app/mtb/logisticsV2/h5-detail?x-ssr=true&bizOrderId=$orderId';
      final response = await client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _ua,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Cookie': cookies,
        },
      );
      if (response.statusCode != 200) {
        _logTb('[Taobao SSR] 物流详情 HTTP ${response.statusCode}，跳过');
        return null;
      }

      final trace = TaobaoTraceParser.parseHtml(response.body, log: _logTb);
      if (trace == null) return null; // 原因已由解析器打出

      final nodes = trace.nodes;
      final stateLabel = trace.stateLabel;
      final stationName = trace.stationName.isNotEmpty ? trace.stationName : '菜鸟驿站';

      // 优先以时间轴推导真实状态（与拼多多通道同一套引擎）；节点时间已规范成 yyyy-MM-dd HH:mm:ss
      String? rawTimelineJson;
      PackageStatus? derivedStatus;
      if (nodes.isNotEmpty) {
        rawTimelineJson = jsonEncode(nodes);
        final derived = LogisticsStatusEngine.derive(
          events: nodes,
          isPendingShipment: _isPendingLabel(stateLabel),
          isOrderSigned: _isSignedLabel(stateLabel) || trace.lgStatus == 'SIGN',
          pickupCode: trace.pickupCode,
          stationName: stationName,
        );
        derivedStatus = derived.status;
      } else {
        _logTb('[Taobao SSR] 物流详情没有可用的轨迹节点，只产出运单信息');
      }

      return _TbParcel(
        mailNo: trace.mailNo,
        cpName: trace.cpName,
        stateLabel: stateLabel,
        pickupCode: trace.pickupCode,
        stationName: stationName,
        location: '',
        rawTimelineJson: rawTimelineJson,
        derivedStatus: derivedStatus,
      );
    } catch (e) {
      // 只记异常类型：ClientException 等的文本会带请求 URL（含订单号）
      _logTb('[Taobao SSR] 物流详情请求或解析异常：${e.runtimeType}');
      return null;
    }
  }

  /// 针对已知运单号直接调用阿里/菜鸟官方 mtop 接口查询到站取件信息
  Future<_CainiaoItem?> _queryCainiaoByMailNo(http.Client client, String cookies, String mailNo) async {
    try {
      final rawJson = await _mtopCall(
        client,
        cookies,
        api: 'mtop.cnwireless.cnlogisticdetailservice.wapquerylogisticpackagebymailno',
        v: '1.0',
        dataRaw: jsonEncode({'mailNo': mailNo}),
      );
      if (rawJson == null || rawJson.isEmpty) return null;
      _logTb('[Cainiao MailNo Query] len=${rawJson.length}');

      final s = stripJsonp(rawJson);
      final root = jsonDecode(s) as Map<String, dynamic>;
      _logTb('[Cainiao MailNo RET] ${root['ret']}');

      // 原「紧凑诊断」会把取件码、驿站名等逐个打进日志，已删除

      final data = root['data'] as Map<String, dynamic>?;
      if (data == null) return null;

      var code = '';
      var station = '';
      var cp = '';

      // 货架码形态（如 9-4-1006 / 16-1-7002），或含数字的短码（如 A108、3021）
      final shelfReg = RegExp(r'^\d{1,3}-\d{1,3}-\d{2,5}$');
      final shortCodeReg = RegExp(r'^(?=.*\d)[A-Za-z0-9\-]{2,12}$');

      bool isPlausibleCode(String v) {
        if (v.isEmpty) return false;
        if (v.length > 14) return false;
        if (RegExp(r'^\d{10,}$').hasMatch(v)) return false; // 纯数字长单号
        if (RegExp(r'^1[3-9]\d{9}$').hasMatch(v)) return false; // 手机号
        if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(v)) return false; // 日期
        return shelfReg.hasMatch(v) || shortCodeReg.hasMatch(v);
      }

      const codeKeys = [
        'takeCode', 'fetchCode', 'pickupCode', 'shelfCode', 'pickCode',
        'pickupNo', 'takeNo', 'fetchNo', 'ticketCode', 'codeValue',
        'pickupCodeText', 'code', 'verifyCode', 'pickCodeText',
      ];
      const stationKeys = ['stationName', 'siteName', 'stationDesc', 'pickupPointName', 'siteAddrName'];
      const cpKeys = ['cpName', 'expressCompanyName', 'cpCode', 'companyName'];

      void walk(dynamic node) {
        if (node is Map) {
          final m = node.cast<String, dynamic>();
          for (final k in codeKeys) {
            final v = m[k]?.toString().trim() ?? '';
            if (isPlausibleCode(v)) {
              // 货架码优先级最高；已有货架码时不再降级覆盖
              final incomingIsShelf = shelfReg.hasMatch(v);
              final currentIsShelf = shelfReg.hasMatch(code);
              if (code.isEmpty || (incomingIsShelf && !currentIsShelf)) {
                code = v;
              }
            }
          }
          // 兜底：字符串值中出现「取件码 XXX」
          for (final v in m.values) {
            if (v is String) {
              final m2 = RegExp(r'取件码[:：\s]*([A-Za-z0-9\-]{2,12})').firstMatch(v);
              if (m2 != null) {
                final c = m2.group(1)!.trim();
                if (isPlausibleCode(c) && code.isEmpty) code = c;
              }
            }
          }
          for (final k in stationKeys) {
            final st = m[k]?.toString().trim() ?? '';
            if (st.isNotEmpty && station.isEmpty) station = st;
          }
          for (final k in cpKeys) {
            final c = m[k]?.toString().trim() ?? '';
            if (c.isNotEmpty && cp.isEmpty) cp = c;
          }
          for (final v in m.values) {
            walk(v);
          }
        } else if (node is List) {
          for (final item in node) {
            walk(item);
          }
        }
      }

      walk(data);

      if (code.isNotEmpty) {
        return _CainiaoItem(
          pickupCode: code,
          trackingNumber: mailNo,
          stationName: station,
          courier: cp,
        );
      }
    } catch (e) {
      _logTb('[Cainiao MailNo Err] ${e.runtimeType}');
    }
    return null;
  }

  Future<String?> _mtopCall(
    http.Client client,
    String cookies, {
    required String api,
    required String v,
    required String dataRaw,
  }) async {
    try {
      var cookieStr = cookies;
      // 标准 mtop 令牌流程：无令牌时先裸发一次，从 Set-Cookie 取新令牌后重试
      for (var attempt = 0; attempt < 3; attempt++) {
        final tokenMatch = RegExp(r'_m_h5_tk=([^;]+)').firstMatch(cookieStr);
        // 令牌缺失时使用空令牌发起引导请求，服务器会通过 Set-Cookie 下发新令牌
        final token = tokenMatch?.group(1)?.split('_').first ?? '';

        final t = DateTime.now().millisecondsSinceEpoch.toString();
        final signSource = '$token&$t&$_appKey&$dataRaw';
        final sign = md5.convert(utf8.encode(signSource)).toString();

        final url = 'https://h5api.m.taobao.com/h5/$api/$v/?jsv=2.3.18&appKey=$_appKey&t=$t&sign=$sign&type=jsonp&dataType=jsonp&data=${Uri.encodeComponent(dataRaw)}';

        final resp = await client.get(
          Uri.parse(url),
          headers: {
            'User-Agent': _ua,
            'Origin': 'https://h5.m.taobao.com',
            'Referer': 'https://h5.m.taobao.com/',
            'Cookie': cookieStr,
          },
        );

        // 解析服务端下发的新令牌（轮换），并持久化，避免会话到期后彻底断联
        final setCookies = resp.headers['set-cookie'] ?? '';
        final newTk = RegExp(r'_m_h5_tk=([^;]+)').firstMatch(setCookies)?.group(1);
        final newTkEnc = RegExp(r'_m_h5_tk_enc=([^;]+)').firstMatch(setCookies)?.group(1);
        if (newTk != null || newTkEnc != null) {
          var updated = cookieStr;
          if (newTk != null) {
            updated = updated.contains('_m_h5_tk=')
                ? updated.replaceAll(RegExp(r'_m_h5_tk=[^;]*'), '_m_h5_tk=$newTk')
                : '$updated; _m_h5_tk=$newTk';
          }
          if (newTkEnc != null) {
            updated = updated.contains('_m_h5_tk_enc=')
                ? updated.replaceAll(RegExp(r'_m_h5_tk_enc=[^;]*'), '_m_h5_tk_enc=$newTkEnc')
                : '$updated; _m_h5_tk_enc=$newTkEnc';
          }
          cookieStr = updated;
          _logTb('[Taobao] mtop token rotated: api=$api');
          // 就地更新令牌字段，不刷新「授权绑定时间」（该时间仅代表用户完成登录的时刻）
          await _authStore.updateCookieTokenFields(
            'taobao',
            token: newTk,
            tokenEnc: newTkEnc,
          );
        }

        final body = resp.body;
        // 会话级失效（登录态已过期）：统一上报，避免静默失败
        if (body.contains('FAIL_SYS_SESSION_EXPIRED') ||
            body.contains('FAIL_SYS_SID_INVALID') ||
            body.contains('您需要登录才能继续访问')) {
          await _markSessionExpired();
          return body;
        }

        final isTokenErr = body.contains('FAIL_SYS_TOKEN_EMPTY') || body.contains('FAIL_SYS_TOKEN_EXPIRED');
        if (isTokenErr && attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 150));
          continue;
        }
        if (isTokenErr) {
          // 令牌多轮轮换重试后仍过期：登录态实质失效，落盘标记供设置页展示「已失效」
          await _markSessionExpired();
        }
        return body;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 统一的登录态失效上报：写内存提示并落盘标记，供设置页动态展示
  Future<void> _markSessionExpired() async {
    _lastIssue = '淘宝登录态已失效，请重新登录授权';
    await _authStore.setExpired('taobao', true);
  }

  /// 剥离 JSONP 外壳（mtopjsonp1({...})），只去掉起止包裹，避免正文括号被误截断
  static String stripJsonp(String raw) {
    var s = raw.trim();
    final m = RegExp(r'^[A-Za-z_$][\w$]*\s*\(').firstMatch(s);
    if (m != null && s.endsWith(')')) {
      s = s.substring(m.end, s.length - 1).trim();
    }
    return s;
  }

  CourierType _resolveCourier(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('顺丰') || lower.contains('sf')) return CourierType.sf;
    if (lower.contains('京东') || lower.contains('jd')) return CourierType.jd;
    if (lower.contains('中通') || lower.contains('zto')) return CourierType.zto;
    if (lower.contains('圆通') || lower.contains('yt')) return CourierType.yt;
    if (lower.contains('申通') || lower.contains('sto')) return CourierType.sto;
    if (lower.contains('韵达') || lower.contains('yd')) return CourierType.yd;
    if (lower.contains('极兔') || lower.contains('jt')) return CourierType.jt;
    if (lower.contains('邮政') || lower.contains('ems')) return CourierType.ems;
    if (lower.contains('德邦') || lower.contains('db')) return CourierType.db;
    if (lower.contains('百世') || lower.contains('best')) return CourierType.best;
    return CourierType.other;
  }

  PackageStatus _resolveStatus(String stateLabel) {
    if (stateLabel.contains('签收') || stateLabel.contains('完成')) return PackageStatus.pickedUp;
    if (stateLabel.contains('待取') || stateLabel.contains('已到') || stateLabel.contains('入库')) return PackageStatus.arrived;
    if (stateLabel.contains('派送') || stateLabel.contains('配送')) return PackageStatus.delivering;
    if (stateLabel.contains('待发货') || stateLabel.contains('等待发货') || stateLabel.contains('未发货')) return PackageStatus.pendingShipment;
    return PackageStatus.transit;
  }

  /// 状态标签是否表示「待发货/未发货」
  bool _isPendingLabel(String label) =>
      label.contains('待发货') || label.contains('未发货') || label.contains('待出库');

  /// 状态标签是否表示「已签收/已完成」
  bool _isSignedLabel(String label) =>
      label.contains('签收') || label.contains('完成') || label.contains('已收货') || label.contains('妥投');
}

class _TbOrder {
  final String orderId;
  final String statusText;
  final String goodsName;
  final String goodsPic;

  /// 订单列表 statusInfo.operations 里有「查看物流」
  final bool hasLogistics;

  _TbOrder({
    required this.orderId,
    required this.statusText,
    required this.goodsName,
    required this.goodsPic,
    required this.hasLogistics,
  });
}

class _TbParcel {
  final String mailNo;
  final String cpName;
  final String stateLabel;
  final String pickupCode;
  final String stationName;
  final String location;
  final String? rawTimelineJson;
  final PackageStatus? derivedStatus;

  _TbParcel({
    required this.mailNo,
    required this.cpName,
    required this.stateLabel,
    required this.pickupCode,
    required this.stationName,
    required this.location,
    this.rawTimelineJson,
    this.derivedStatus,
  });
}
