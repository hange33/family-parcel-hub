/// 平台H5登录页面 - 在沙盒WebView中进行登录并安全提取Cookie
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../platform/connectors/pdd_parse_diag.dart';
import '../../../platform/storage/platform_auth_store.dart';
import '../../../platform/webview/platform_cookie.dart';

class PlatformLoginScreen extends StatefulWidget {
  final String platform; // taobao, jd, pdd
  final String displayName;
  final Color brandColor;
  final String? initialUrl;

  const PlatformLoginScreen({
    super.key,
    required this.platform,
    required this.displayName,
    required this.brandColor,
    this.initialUrl,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String platform,
    required String displayName,
    required Color brandColor,
    String? initialUrl,
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PlatformLoginScreen(
          platform: platform,
          displayName: displayName,
          brandColor: brandColor,
          initialUrl: initialUrl,
        ),
      ),
    );
  }

  @override
  State<PlatformLoginScreen> createState() => _PlatformLoginScreenState();
}

class _PlatformLoginScreenState extends State<PlatformLoginScreen> {
  late final WebViewController _controller;
  int _loadingProgress = 0;
  bool _isSaving = false;

  String get _initialUrl {
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      return widget.initialUrl!;
    }
    switch (widget.platform.toLowerCase()) {
      case 'taobao':
      case 'tmall':
        return 'https://main.m.taobao.com/';
      case 'jd':
        return 'https://plogin.m.jd.com/login/login?appid=100&returnurl=https://home.m.jd.com/';
      case 'pdd':
        // family-hub: 改走「网页端包裹助手」。扫码登录不会顶掉手机官方 App，
        // 且该页面本身带取件码，可直接作为抓取入口。
        return 'https://mobile.pinduoduo.com/psnl_goods_help.html'
            '?_t_module_name=assistant_search';
      default:
        return 'https://main.m.taobao.com/';
    }
  }

  /// 登录页 UA
  ///
  /// family-hub: 拼多多必须用**桌面 UA**。
  /// 用安卓 UA 时拼多多只会给「手机版登录页」（跳转 App / 手机登录），
  /// 而手机登录走的是 App 同一套会话，会顶掉官方 App；
  /// 桌面 UA 才会出「扫码登录」，实测该会话与手机 App 相互独立。
  String get _loginUserAgent {
    switch (widget.platform.toLowerCase()) {
      case 'pdd':
        return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
      default:
        return 'Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
    }
  }

  @override
  void initState() {
    super.initState();
    debugPrint('[PDDLogin] platform=${widget.platform} ua=$_loginUserAgent');
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_loginUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _loadingProgress = progress);
          },
          onNavigationRequest: (request) {
            final url = request.url;
            final lower = url.toLowerCase();
            // 非 http(s) 的 DeepLink（如 pinduoduo://、taobao://）：交给系统用官方客户端打开
            if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
              debugPrint('[WebView] External app scheme: $url');
              _openExternalApp(url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            debugPrint('[WebView Error] code: ${error.errorCode}, desc: ${error.description}');
          },
          onPageFinished: (url) async {
            debugPrint('[PDDLogin] landed: $url');
            // family-hub: 拼多多强制桌面视口，否则窄屏会走响应式手机布局，
            // 即使 UA 是桌面版也看不到「扫码登录」入口。
            if (widget.platform.toLowerCase() == 'pdd') {
              await _forceDesktopViewport();
            }
            _checkAutoLogin(url);
            // 拼多多扫码后可能停在首页/中转页，URL 判断会漏；直接看 Cookie 更可靠
            if (widget.platform.toLowerCase() == 'pdd') {
              await _maybeSavePddLogin();
            }
          },
        ),
      );

    _initAndLoad();
  }

  /// 拼多多登录成功判定：只要 Cookie 里出现登录令牌就保存，
  /// 不依赖具体落在哪个 URL（扫码后跳转路径可能变化）。
  Future<void> _maybeSavePddLogin() async {
    if (_isSaving) return;
    try {
      final cookieManager = WebViewCookieManager();
      var logged = false;
      for (final host in _cookieHosts) {
        try {
          final list = await cookieManager.getCookies(domain: Uri.parse(host));
          if (list.any((c) =>
              c.name == 'pdd_user_id' || c.name == 'PDDAccessToken')) {
            logged = true;
            break;
          }
        } catch (_) {}
      }
      if (logged) {
        debugPrint('[PDDLogin] pdd login cookie detected, saving');
        await _extractAndSaveCookies(silent: true);
      }
    } catch (e) {
      debugPrint('[PDDLogin] cookie check failed: $e');
    }
  }

  /// family-hub: 把页面视口强制成桌面宽度，触发桌面版布局
  Future<void> _forceDesktopViewport() async {
    const js = r"""
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
    try {
      await _controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[PDDLogin] force viewport failed: $e');
    }
  }

  /// 先注入已保存的登录态（若有），再加载页面，避免用户重复登录
  Future<void> _initAndLoad() async {    final saved = PlatformAuthStore().getCookies(widget.platform);
    if (saved != null && saved.trim().isNotEmpty) {
      final hosts = _cookieHosts.map((e) => Uri.parse(e).host).toSet();
      // 补充根域，确保阿里 SSO 全域有效
      if (widget.platform.toLowerCase() == 'taobao' || widget.platform.toLowerCase() == 'tmall') {
        hosts.addAll(['.taobao.com', '.m.taobao.com', '.cainiao.com']);
      }
      // 原生注入，保留 HttpOnly/Secure，避免会话令牌被页面脚本读取
      await injectCookieString(cookies: saved, domains: hosts.toList());
      debugPrint('[Login] Injected saved cookies for ${widget.platform}');
    }
    await _controller.loadRequest(Uri.parse(_initialUrl));
  }

  List<String> get _cookieHosts {
    switch (widget.platform.toLowerCase()) {
      case 'taobao':
      case 'tmall':
        return [
          'https://h5.m.taobao.com',
          'https://main.m.taobao.com',
          'https://m.taobao.com',
          'https://www.taobao.com',
          'https://login.m.taobao.com',
          'https://login.taobao.com',
          'https://passport.taobao.com',
          'https://h5api.m.taobao.com',
          'https://pages-fast.m.taobao.com',
          'https://page.cainiao.com',
          'https://pages.cainiao.com',
          'https://m.cainiao.com',
          'https://cainiao.com',
          'https://taobao.com',
        ];
      case 'jd':
        return [
          'https://www.jd.com',
          'https://home.m.jd.com',
          'https://trade.m.jd.com',
          'https://api.m.jd.com',
        ];
      case 'pdd':
        return [
          'https://mobile.yangkeduo.com',
          'https://yangkeduo.com',
          'https://mobile.pinduoduo.com',
        ];
      default:
        return [];
    }
  }

  Future<void> _checkAutoLogin(String url) async {
    final lowerUrl = url.toLowerCase();
    // 检查URL是否已经跳过登录页，进入个人中心或订单中心
    final isHomeOrOrder = switch (widget.platform.toLowerCase()) {
      'taobao' => lowerUrl.contains('my_taobao') ||
          lowerUrl.contains('mytaobao') ||
          lowerUrl.contains('order') ||
          lowerUrl.contains('cainiao') ||
          lowerUrl.contains('station') ||
          lowerUrl.contains('last-mile-fe'),
      'jd' => lowerUrl.contains('home.m.jd.com') || lowerUrl.contains('orderlist') || lowerUrl.contains('trade.m.jd.com'),
      // family-hub: 包裹助手页（psnl_goods_help）即视为已登录落点
      'pdd' => !lowerUrl.contains('login') &&
          (lowerUrl.contains('psnl_goods_help') ||
              lowerUrl.contains('orders') ||
              lowerUrl.contains('personal') ||
              lowerUrl.contains('index') ||
              lowerUrl.contains('home')),
      _ => false,
    };

    if (isHomeOrOrder && !_isSaving) {
      await _extractAndSaveCookies(silent: true);
    }
  }

  /// 记录当前页面地址，供连接器复用（用户实际到达的页面才是有效的抓取入口）
  Future<void> _rememberEntryUrl() async {
    try {
      final href = await _controller.runJavaScriptReturningResult('location.href');
      var s = href.toString();
      if (s.startsWith('"') && s.endsWith('"')) {
        s = s.substring(1, s.length - 1);
      }
      if (s.startsWith('http')) {
        await PlatformAuthStore().saveEntryUrl(widget.platform, s);
        debugPrint('[Login] entry url saved: $s');
      }
    } catch (_) {}
  }

  /// 页面是否属于当前平台的可信域（用于决定是否采集页面级凭据）
  bool _isTrustedHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty) return false;
    for (final entry in _cookieHosts) {
      final base = Uri.parse(entry).host.toLowerCase();
      if (h == base || h.endsWith('.$base') || base.endsWith('.$h')) return true;
    }
    switch (widget.platform.toLowerCase()) {
      case 'taobao':
      case 'tmall':
        return h.endsWith('taobao.com') || h.endsWith('tmall.com') || h.endsWith('cainiao.com');
      case 'jd':
        return h.endsWith('jd.com');
      case 'pdd':
        return h.endsWith('yangkeduo.com') || h.endsWith('pinduoduo.com');
      default:
        return false;
    }
  }

  /// 合并收集凭据：native CookieManager（含 HttpOnly）+ document.cookie + localStorage
  ///
  /// 页面级的 document.cookie / localStorage 只在当前页面属于本平台可信域时采集，
  /// 否则会把支付中转页（微信/支付宝）等第三方会话混入平台凭据。
  Future<String> _collectCredential() async {
    final cookieMap = <String, String>{};

    // 1) native CookieManager（可获取 HttpOnly 关键登录态，天然按域隔离）
    final cookieManager = WebViewCookieManager();
    for (final host in _cookieHosts) {
      try {
        final cookies = await cookieManager.getCookies(domain: Uri.parse(host));
        for (final c in cookies) {
          if (c.name.isNotEmpty && c.value.isNotEmpty) {
            cookieMap[c.name] = c.value;
          }
        }
      } catch (e) {
        debugPrint('[Login] getCookies($host) error: $e');
      }
    }

    var currentHost = '';
    try {
      final h = await _controller.runJavaScriptReturningResult('location.host || ""');
      currentHost = h.toString().replaceAll('"', '').trim();
    } catch (_) {}
    final trustedPage = _isTrustedHost(currentHost);
    if (!trustedPage) {
      debugPrint('[Login] skip page-level credential: host "$currentHost" not in platform domains');
      return cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    // 2) document.cookie
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
    } catch (e) {
      debugPrint('[Login] document.cookie error: $e');
    }

    // 3) localStorage 中可能的登录令牌
    try {
      final lsResult = await _controller.runJavaScriptReturningResult('''
(function(){
  var out = [];
  try {
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      if (k && (k.indexOf('uid') !== -1 || k.indexOf('user') !== -1 || k.indexOf('token') !== -1 || k.indexOf('User') !== -1)) {
        out.push(k + '=' + localStorage.getItem(k));
      }
    }
  } catch(e) {}
  return out.join('; ');
})()
''');
      var raw = lsResult.toString();
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
    } catch (e) {
      debugPrint('[Login] localStorage error: $e');
    }

    return cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 允许唤起外部客户端深链的 scheme 白名单（仅各平台官方 App 与支付应用）
  static const Set<String> _allowedDeepLinkSchemes = {
    'taobao',
    'tmall',
    'taobaowireless',
    'openapp.jdmobile',
    'jdmobile',
    'pinduoduo',
    'pdd',
    'alipays',
    'alipay',
    'weixin',
  };

  /// 用系统外部应用打开 DeepLink（跳转电商官方客户端）；未安装时给出提示
  Future<void> _openExternalApp(String url) async {
    try {
      final uri = Uri.parse(url);
      // 白名单校验，避免页面通过任意 scheme 唤起其它应用（短信、电话等）
      if (!_allowedDeepLinkSchemes.contains(uri.scheme.toLowerCase())) {
        debugPrint('[WebView] blocked deep link scheme: ${uri.scheme}');
        _showNoAppHint();
        return;
      }
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        _showNoAppHint();
      }
    } catch (e) {
      debugPrint('[WebView] launch external failed: $e');
      if (mounted) _showNoAppHint();
    }
  }

  void _showNoAppHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('未检测到对应的官方客户端，请使用页面内的「手机登录」完成登录'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 4),
      ),
    );
  }

  /// 平台登录态严格判定。
  ///
  /// 匿名访客访问淘宝 H5 也会下发 `_m_h5_tk` 等请求令牌，因此不能用「命中任一
  /// 字段」来判定登录成功，必须用真正代表已登录的会话字段组合：
  ///   - 淘宝/天猫：`cookie2` 且（`unb` 或 `cookie1`）
  ///   - 京东：`pt_key` 且 `pt_pin`
  ///   - 拼多多：任一会话令牌
  /// 只取 Cookie 名，用于诊断（不记录值）
  List<String> _cookieNames(String cookieStr) {
    final out = <String>[];
    for (final part in cookieStr.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final n = part.substring(0, idx).trim();
      if (n.isNotEmpty) out.add(n);
    }
    return out;
  }

  bool _hasLoginSession(String cookieStr) {
    String? valueOf(String name) {
      for (final part in cookieStr.split(';')) {
        final idx = part.indexOf('=');
        if (idx <= 0) continue;
        if (part.substring(0, idx).trim() == name) {
          final v = part.substring(idx + 1).trim();
          if (v.isNotEmpty) return v;
        }
      }
      return null;
    }

    switch (widget.platform.toLowerCase()) {
      case 'taobao':
      case 'tmall':
        return valueOf('cookie2') != null &&
            (valueOf('unb') != null || valueOf('cookie1') != null);
      case 'jd':
        return valueOf('pt_key') != null && valueOf('pt_pin') != null;
      case 'pdd':
        return valueOf('PDDAccessToken') != null ||
            valueOf('pdd_user_id') != null ||
            valueOf('pdduid') != null ||
            valueOf('AccessToken') != null;
      default:
        return false;
    }
  }

  Future<void> _extractAndSaveCookies({bool silent = false, bool force = false}) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final cookieStr = await _collectCredential();
      final names = _cookieNames(cookieStr);
      PddParseDiag.lastCookieNames = names;
      debugPrint('[Login] Collected credential length: ${cookieStr.length}');
      debugPrint('[Login] cookie names: $names');

      if (cookieStr.trim().isEmpty) {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未检测到有效登录信息，请先在页面完成登录')),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      final store = PlatformAuthStore();
      final newHasToken = _hasLoginSession(cookieStr);
      final stored = store.getCookies(widget.platform);
      final storedHasToken = stored != null && _hasLoginSession(stored);

      // 防止「匿名会话覆盖已登录凭据」：新数据不含登录令牌但旧数据含有时，拒绝覆盖
      if (!force && !newHasToken && storedHasToken) {
        debugPrint('[Login] Reject downgrade: new credential has no login token');
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('尚未检测到登录完成，请先在页面中完成登录后再点击绑定'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      // 未登录成功且原本就没绑定，同样提示用户
      if (!force && !newHasToken && !storedHasToken) {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('尚未检测到登录完成，请先在页面中完成登录后再点击绑定'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      await store.saveCookies(widget.platform, cookieStr);
      await store.setExpired(widget.platform, false);
      await _rememberEntryUrl();

      HapticFeedback.mediumImpact();
      if (mounted) {
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${widget.displayName} 账号绑定成功！'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取凭据异常: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 会话冲突风险提示文案（null 表示无已知风险）
  String? get _riskWarning {
    if (widget.platform.toLowerCase() == 'pdd') {
      return '提示：在此登录会导致拼多多官方 App 退出登录（平台服务端单设备会话限制）';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '登录 ${widget.displayName}',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        backgroundColor: widget.brandColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: '重新加载',
            onPressed: () => _controller.reload(),
          ),
          TextButton(
            onPressed: _isSaving
                ? null
                : () => _extractAndSaveCookies(silent: false, force: true),
            child: _isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '已完成登录',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_riskWarning != null)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF8EF),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 15, color: Colors.orange.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _riskWarning!,
                      style: TextStyle(fontSize: 11.5, height: 1.35, color: Colors.orange.shade900),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loadingProgress < 100)
                  LinearProgressIndicator(
                    value: _loadingProgress / 100.0,
                    color: widget.brandColor,
                    backgroundColor: Colors.transparent,
                    minHeight: 2.5,
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          child: FilledButton.icon(
            onPressed: _isSaving ? null : () => _extractAndSaveCookies(silent: false),
            icon: const Icon(Icons.check_circle_rounded),
            label: const Text(
              '已在页面完成登录，点击绑定账号',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: widget.brandColor,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ),
    );
  }
}
