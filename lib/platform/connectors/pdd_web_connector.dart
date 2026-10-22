/// 拼多多「网页端包裹助手」连接器 —— 替代原来的 H5 订单接口抓取
///
/// 背景（2026-10-20 实测）：
///   - 走 `mobile.yangkeduo.com` 的 H5 登录与手机 App **双向互踢**，官方 App 会掉线；
///   - 走 `mobile.pinduoduo.com/psnl_goods_help.html`（包裹助手）扫码登录，
///     **不会顶掉手机 App**，且页面本身带取件码。
///
/// 因此本连接器只做一件事：在隐藏 WebView 里打开包裹助手页，把页面文本抓回来解析。
/// 原 [PddH5Connector] 保留在仓库里不再注册（避免误踢），日后上游修复可直接切回。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/models/package.dart';
import '../../core/models/package_status.dart';
import '../storage/platform_auth_store.dart';
import '../webview/platform_cookie.dart';
import 'pdd_parse_diag.dart';
import 'platform_connector.dart';

class PddWebConnector implements PlatformConnector {
  PddWebConnector({PlatformAuthStore? authStore, this.desktopUa = true})
      : _authStore = authStore ?? PlatformAuthStore();

  final PlatformAuthStore _authStore;

  /// 复现「电脑浏览器扫码不踢 App」的条件：默认用桌面 UA。
  /// 若包裹助手页在桌面 UA 下布局异常，把这里改成 false 退回移动 UA。
  final bool desktopUa;

  static const _entryUrl =
      'https://mobile.pinduoduo.com/psnl_goods_help.html?_t_module_name=assistant_search';

  /// 抓取候选页（同一桌面会话下）。取第一个能解析出取件码的页面。
  static const _candidateUrls = <String>[
    _entryUrl,
    'https://mobile.pinduoduo.com/orders.html',
    'https://mobile.pinduoduo.com/personal.html',
  ];

  static const _uaDesktop =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const _uaMobile =
      'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  /// Cookie 落盘/注入的域（包裹助手在 pinduoduo.com，与 yangkeduo.com 不同域）
  static const _domains = <String>[
    'mobile.pinduoduo.com',
    '.pinduoduo.com',
    'pinduoduo.com',
  ];

  static const _persistHosts = <String>[
    'https://mobile.pinduoduo.com',
    'https://pinduoduo.com',
  ];

  /// 把视口强制成桌面宽度，触发桌面版布局（窄屏会走手机布局，取件码可能不渲染）
  static const _desktopViewportJs = r"""
(function () {
  try {
    var w = 1280;
    var scale = (window.innerWidth / w).toFixed(3);
    var m = document.querySelector('meta[name="viewport"]');
    if (!m) {
      m = document.createElement('meta');
      m.setAttribute('name', 'viewport');
      document.head.appendChild(m);
    }
    m.setAttribute('content', 'width=' + w + ', initial-scale=' + scale + ', maximum-scale=3');
  } catch (e) {}
})();
""";

  WebViewController? _controller;
  bool _busy = false;
  Completer<void>? _pageDone;
  String? _lastIssue;

  @override
  String get platformId => 'pdd';

  @override
  String get displayName => '拼多多';

  @override
  String get brandColorHex => '#E02E24';

  @override
  String? get lastIssue => _lastIssue;

  void clearLastIssue() => _lastIssue = null;

  @override
  Future<bool> isAuthenticated() async {
    final cookies = _authStore.getCookies('pdd');
    // family-hub: 不再用「失效标记」一票否决。
    // 之前只要标记过一次失效，同步就会被跳过 → 页面明明登录着也永远拿不到数据。
    // 现在有凭据就允许尝试，真失效时同步会重新打上标记。
    return _authStore.isBound('pdd') &&
        cookies != null &&
        cookies.trim().isNotEmpty;
  }

  @override
  Future<void> cancelSync() async {
    _busy = false;
  }

  // ------------------------------------------------------------------ 同步
  @override
  Stream<Package> streamSync() async* {
    if (_busy) {
      debugPrint('[PDDWeb] busy, skip');
      return;
    }
    final cookies = _authStore.getCookies('pdd');
    if (cookies == null || cookies.trim().isEmpty) {
      debugPrint('[PDDWeb] no cookies');
      return;
    }

    _busy = true;
    try {
      _lastIssue = null;
      await _injectCookies(cookies);
      await _ensureController();

      // 依次尝试候选页：包裹助手 → 订单列表 → 个人中心。
      // 实测包裹助手页在桌面版下可能夹带推荐/广告内容，未必是本人包裹，
      // 所以不能只认一个页面，也不能把页面里的商品标题当取件码。
      var packages = <Package>[];
      var sawLoginPage = false;
      var probeText = '';
      for (final url in _candidateUrls) {
        final text = await _loadAndReadText(url);
        if (text == null || text.trim().isEmpty) {
          debugPrint('[PDDWeb] empty text: $url');
          continue;
        }
        probeText = text;
        PddParseDiag.recordPage(url, text);

        final parsed = parseHelperText(
          text,
          url: url,
          userAgent: desktopUa ? _uaDesktop : _uaMobile,
        );
        debugPrint('[PDDWeb] $url -> ${parsed.length} packages');
        if (parsed.isNotEmpty) {
          packages = parsed;
          break;
        }
        if (_looksLikeLoginPage(text)) {
          sawLoginPage = true;
          break;
        }
      }

      if (packages.isEmpty) {
        if (sawLoginPage) {
          _lastIssue = '拼多多网页登录已失效，请重新绑定';
          await _authStore.setExpired('pdd', true);
          debugPrint('[PDDWeb] looks like login page, mark expired');
        } else {
          _lastIssue = '拼多多未解析到取件码｜页面首行：${_firstLine(probeText)}';
        }
        return;
      }

      await _authStore.setExpired('pdd', false);
      await _persistCookiesIfHealthy(cookies);

      for (final p in packages) {
        yield p;
      }
    } catch (e, st) {
      debugPrint('[PDDWeb] sync error: $e\n$st');
      _lastIssue = '拼多多网页抓取异常，已保留旧数据';
    } finally {
      _busy = false;
    }
  }

  Future<void> _ensureController() async {
    if (_controller != null) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(desktopUa ? _uaDesktop : _uaMobile)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          final c = _pageDone;
          if (c != null && !c.isCompleted) c.complete();
        },
        onWebResourceError: (e) => debugPrint('[PDDWeb] resource error: ${e.description}'),
        onNavigationRequest: (req) {
          final url = req.url.toLowerCase();
          if (!url.startsWith('http://') && !url.startsWith('https://')) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ));
    _controller = controller;
  }

  Future<void> _injectCookies(String cookies) async {
    await injectCookieString(cookies: cookies, domains: _domains);
  }

  /// 打开包裹助手页并取回正文；失败返回 null
  Future<String?> _loadAndReadText(String url) async {
    final controller = _controller;
    if (controller == null) return null;

    _pageDone = Completer<void>();
    try {
      await controller.loadRequest(Uri.parse(url));
    } catch (e) {
      debugPrint('[PDDWeb] load error: $e');
    }
    try {
      await _pageDone!.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      debugPrint('[PDDWeb] page load timeout, try reading anyway');
    }

    // 与登录页一致：强制桌面视口，避免窄屏走响应式手机布局
    try {
      await controller.runJavaScript(_desktopViewportJs);
    } catch (_) {}

    // 懒加载：滚到底，再读正文
    for (var i = 0; i < 3; i++) {
      try {
        await controller.runJavaScript(
            'window.scrollTo(0, document.body.scrollHeight);');
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final raw = await controller
            .runJavaScriptReturningResult('document.body.innerText');
        final text = _asString(raw);
        if (text.length > 120) return text;
      } catch (e) {
        debugPrint('[PDDWeb] read text failed: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    return null;
  }

  static String _firstLine(String text) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.length >= 2) {
        return t.length > 40 ? t.substring(0, 40) : t;
      }
    }
    return '（空）';
  }

  static String _asString(Object? raw) {
    if (raw == null) return '';
    final s = raw.toString();
    // Android 返回 JSON 字符串（带引号与转义），iOS 直接返回原文
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s
          .substring(1, s.length - 1)
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', '\\');
    }
    return s;
  }

  Future<void> _persistCookiesIfHealthy(String originalCookies) async {
    try {
      final manager = WebViewCookieManager();
      final map = <String, String>{};
      for (final host in _persistHosts) {
        try {
          final list = await manager.getCookies(domain: Uri.parse(host));
          for (final c in list) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) map[c.name] = c.value;
          }
        } catch (_) {}
      }
      if (map.isEmpty) return;
      final hasToken = map.keys.any((k) =>
          k.contains('PDDAccessToken') ||
          k.contains('pdd_user_id') ||
          k.contains('pdduid'));
      if (!hasToken) return;
      final merged = map.entries.map((e) => '${e.key}=${e.value}').join('; ');
      if (merged == originalCookies) return;
      await _authStore.saveCookies('pdd', merged);
      debugPrint('[PDDWeb] cookies refreshed (len ${merged.length})');
    } catch (e) {
      debugPrint('[PDDWeb] persist cookies error: $e');
    }
  }

  bool _looksLikeLoginPage(String text) {
    final t = text.replaceAll(' ', '');
    final hasLoginWord = t.contains('登录') || t.contains('扫码');
    final hasPackageWord =
        t.contains('取件码') || t.contains('待取') || t.contains('包裹');
    return hasLoginWord && !hasPackageWord;
  }

  // ------------------------------------------------------------------ 解析
  static final RegExp _codeRe = RegExp(r'\b\d{1,3}-\d{1,3}-\d{2,5}\b');
  static final RegExp _trackRe = RegExp(
      r'\b(?:JT|SF|YT|ST|JD|ZTO|YD|EMS|DB)[A-Z0-9]{8,16}\b',
      caseSensitive: false);
  static final RegExp _stationRe = RegExp(
      r'([\u4e00-\u9fa5A-Za-z0-9()（）\-]{2,30}?(?:驿站|自提点|快递柜|服务站|代收点))');

  /// 取件码标签：只有跟在标签后面的码，或独占一行的码，才算真取件码
  static final RegExp _labelRe = RegExp(r'(取件码|取货码|提货码|凭码|取件号)[\s:：]*');

  /// 商品标题里常见的型号词，用于排除「1.5-2.2-7.5-11-22-630kw」这类误命中
  static final RegExp _modelRe = RegExp(
      r'(变频器|电机|马达|水泵|功率|电压|型号|规格|适用|通用|重载|轴承|电池|容量|尺寸|管|阀|泵|KW|kW|V|W)');

  /// 纯文本 → 包裹列表
  ///
  /// 之前的问题：在整页里搜 `\d-\d-\d`，把商品型号 `1.5-2.2-7.5-11-22-630kw`
  /// 截成了取件码 `5-11-22`。现在改为**只认两种形态**：
  ///   1) 跟在「取件码」等标签后面的码；
  ///   2) 独占一行的码（表格单元格）。
  /// 并对未带标签的候选做型号词过滤。
  static List<Package> parseHelperText(
    String text, {
    DateTime? now,
    String url = '',
    String userAgent = '',
  }) {
    final ts = now ?? DateTime.now();
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final byKey = <String, Package>{};
    final rejected = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final label = _labelRe.firstMatch(line);

      String? code;
      if (label != null) {
        final after = line.substring(label.end);
        code = _codeRe.firstMatch(after)?.group(0) ?? _codeRe.firstMatch(line)?.group(0);
      } else {
        // 独占一行的码（表格单元格形态）
        final m = _codeRe.firstMatch(line);
        if (m != null && m.group(0) == line) code = m.group(0);
      }
      if (code == null) continue;

      final from = (i - 2).clamp(0, lines.length);
      final to = (i + 3).clamp(0, lines.length);
      final ctx = lines.sublist(from, to).join(' ');

      // 未带标签的候选：上下文里出现型号词 → 判定为商品型号，丢弃
      if (label == null && _modelRe.hasMatch(ctx)) {
        if (rejected.length < 12) rejected.add('$code ← ${line.substring(0, line.length > 40 ? 40 : line.length)}');
        continue;
      }

      // 已取件/已签收的不入库（取件完成由用户手动确认）
      if (ctx.contains('已取件') || ctx.contains('已签收') || ctx.contains('已提取')) {
        continue;
      }

      final station = _stationRe.firstMatch(ctx)?.group(1) ?? '';
      final track = _trackRe.firstMatch(ctx)?.group(0) ?? '';
      final goods = _guessGoodsName(lines, i);
      final id = 'PDD_${track.isNotEmpty ? track : code}';

      byKey[id] = Package(
        id: id,
        trackingNumber: track,
        courier: CourierType.other,
        pickupCode: code,
        location: '',
        originalStation: station,
        stationName: station.isEmpty ? null : station,
        goodsName: goods.isEmpty ? null : goods,
        description: '',
        urgency: UrgencyLevel.normal,
        status: PackageStatus.arrived,
        addedAt: ts,
        platform: 'pdd',
      );
    }

    PddParseDiag.recordParse(
      url: url,
      lineCount: lines.length,
      accepted: byKey.length,
      rejected: rejected,
      userAgent: userAgent,
    );
    return byKey.values.toList(growable: false);
  }

  /// 往上找最近的「像商品名」的一行，作为卡片标题
  static String _guessGoodsName(List<String> lines, int codeIndex) {
    for (var j = codeIndex - 1; j >= 0 && j >= codeIndex - 8; j--) {
      final s = lines[j];
      if (s.length < 4 || s.length > 60) continue;
      if (_labelRe.hasMatch(s)) continue;
      if (_stationRe.hasMatch(s)) continue;
      if (s.contains('取件') || s.contains('物流') || s.contains('查看') ||
          s.contains('待取') || s.contains('已到')) {
        continue;
      }
      if (RegExp(r'^[\d\s\-:.]+$').hasMatch(s)) continue;
      return s;
    }
    return '';
  }
}
