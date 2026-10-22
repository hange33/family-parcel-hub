/// 平台账号凭据与Cookie安全存储
///
/// 凭据在落盘前用 Android Keystore 中的 AES-GCM 主密钥加密（`enc:v1:` 前缀标识），
/// 主密钥不可导出且不随备份迁移；设备不支持 Keystore 时降级为明文存储（仅老设备）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'keep_alive_store.dart';

/// 平台凭据存储 Box 名称（在 main.dart 启动时预先打开）
const String kPlatformAuthBox = 'platform_auth_box';

const MethodChannel _secureStoreChannel =
    MethodChannel('com.example.pickup_app/secure_store');

/// 加密值前缀：用于区分历史明文数据并触发自动迁移
const String _encryptedPrefix = 'enc:v1:';

final platformAuthStoreProvider = Provider<PlatformAuthStore>((ref) {
  return PlatformAuthStore();
});

class PlatformAuthStore {
  static const String _boxName = kPlatformAuthBox;

  Box? _box;

  /// 解密后的凭据内存缓存（platform -> cookies），避免同步读取路径需要 await
  static final Map<String, String> _plainCache = {};
  static bool _preloaded = false;

  static String _cookieKey(String platform) => '${platform.toLowerCase()}_cookies';

  static Future<String> _encrypt(String plain) async {
    try {
      final encoded = await _secureStoreChannel
          .invokeMethod<String>('encrypt', {'value': plain});
      if (encoded != null && encoded.isNotEmpty) {
        return '$_encryptedPrefix$encoded';
      }
    } catch (e) {
      debugPrint('[AuthStore] encrypt unavailable, storing plaintext: $e');
    }
    return plain;
  }

  /// 返回明文；历史明文原样返回，密文解密失败返回 null
  static Future<String?> _decrypt(String stored) async {
    if (!stored.startsWith(_encryptedPrefix)) return stored;
    try {
      final plain = await _secureStoreChannel.invokeMethod<String>(
        'decrypt',
        {'value': stored.substring(_encryptedPrefix.length)},
      );
      return plain;
    } catch (e) {
      debugPrint('[AuthStore] decrypt failed: $e');
      return null;
    }
  }

  /// 预加载并解密全部平台凭据；顺带把历史明文重新加密落盘
  static Future<void> _preload() async {
    if (_preloaded) return;
    try {
      final box = Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : null;
      if (box == null) return;
      var migrated = false;
      for (final key in box.keys) {
        final k = key.toString();
        if (!k.endsWith('_cookies')) continue;
        final raw = box.get(key) as String?;
        if (raw == null || raw.isEmpty) continue;
        final platform = k.substring(0, k.length - '_cookies'.length);
        final plain = await _decrypt(raw);
        if (plain == null) continue;
        _plainCache[platform] = plain;
        if (!raw.startsWith(_encryptedPrefix)) {
          // 迁移历史明文
          final encrypted = await _encrypt(plain);
          if (encrypted != plain) {
            await box.put(k, encrypted);
            migrated = true;
          }
        }
      }
      // Hive 是追加式日志：压缩一次才能真正抹掉磁盘上残留的明文帧
      if (migrated) await box.compact();
      // 加密改造前写入的明文帧无法通过 API 识别，做一次性压缩确保其被清除
      const compactedKey = '_encrypted_compacted_v1';
      if (box.get(compactedKey) != true) {
        await box.compact();
        await box.put(compactedKey, true);
      }
      _preloaded = true;
    } catch (e) {
      debugPrint('[AuthStore] preload error: $e');
    }
  }

  /// 获取已打开的 Box（未打开时尝试直接取用，仍失败则返回 null）
  Box? get _safeBox {
    if (_box != null && _box!.isOpen) return _box;
    if (Hive.isBoxOpen(_boxName)) {
      _box = Hive.box(_boxName);
      return _box;
    }
    return null;
  }

  Future<void> _ensureInit() async {
    if (_box != null && _box!.isOpen) {
      await _preload();
      return;
    }
    _box = Hive.isBoxOpen(_boxName)
        ? Hive.box(_boxName)
        : await Hive.openBox(_boxName);
    await _preload();
  }

  /// 启动时预打开存储并解密凭据（在 main.dart 中调用，确保重启后凭据可读）
  static Future<void> initialize() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
    await _preload();
  }

  Future<void> saveCookies(String platform, String cookies) async {
    await _ensureInit();
    final p = platform.toLowerCase();
    _plainCache[p] = cookies;
    await _box!.put(_cookieKey(p), await _encrypt(cookies));
    await _box!.put(
      '${p}_updated_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    // 重新绑定时清除旧的失效标记
    await setExpired(p, false);
  }

  /// 仅就地更新 mtop 令牌字段，不刷新「授权绑定时间」
  ///
  /// 令牌轮换是后台自动行为，不能改写代表用户登录时刻的 updated_at，
  /// 否则设置页显示的授权日期会被反复重置。
  Future<void> updateCookieTokenFields(
    String platform, {
    String? token,
    String? tokenEnc,
  }) async {
    await _ensureInit();
    final p = platform.toLowerCase();
    final stored = getCookies(p);
    if (stored == null || stored.isEmpty) return;
    var merged = stored;
    if (token != null) {
      merged = merged.contains('_m_h5_tk=')
          ? merged.replaceAll(RegExp(r'_m_h5_tk=[^;]*'), '_m_h5_tk=$token')
          : '$merged; _m_h5_tk=$token';
    }
    if (tokenEnc != null) {
      merged = merged.contains('_m_h5_tk_enc=')
          ? merged.replaceAll(RegExp(r'_m_h5_tk_enc=[^;]*'), '_m_h5_tk_enc=$tokenEnc')
          : '$merged; _m_h5_tk_enc=$tokenEnc';
    }
    _plainCache[p] = merged;
    await _box!.put(_cookieKey(p), await _encrypt(merged));
  }

  /// 标记/清除登录失效状态（以时间戳形式存储，避免布尔标记被其它写入路径覆盖）
  Future<void> setExpired(String platform, bool expired) async {
    await _ensureInit();
    final key = '${platform.toLowerCase()}_expired_at';
    if (expired) {
      await _box!.put(key, DateTime.now().millisecondsSinceEpoch);
    } else {
      await _box!.delete(key);
    }
  }

  bool isExpired(String platform) {
    final box = _safeBox;
    if (box == null || !box.isOpen) return false;
    return box.get('${platform.toLowerCase()}_expired_at') != null;
  }

  /// 读取凭据明文（优先命中已解密的内存缓存）
  String? getCookies(String platform) {
    final p = platform.toLowerCase();
    final cached = _plainCache[p];
    if (cached != null && cached.isNotEmpty) return cached;
    final box = _safeBox;
    if (box == null || !box.isOpen) return null;
    final raw = box.get(_cookieKey(p)) as String?;
    // 未预加载（或解密失败）时不返回密文，避免把密文当凭据使用
    if (raw == null || raw.startsWith(_encryptedPrefix)) return null;
    return raw;
  }

  bool isBound(String platform) {
    final cookies = getCookies(platform);
    return cookies != null && cookies.trim().isNotEmpty;
  }

  Future<void> unbind(String platform) async {
    await _ensureInit();
    final p = platform.toLowerCase();
    _plainCache.remove(p);
    await _box!.delete(_cookieKey(p));
    await _box!.delete('${p}_updated_at');
    await _box!.delete('${p}_entry_url');
    await _box!.delete('${p}_expired_at');
    // 同时清掉保活调度状态，避免重新绑定时继承旧的闸门与失败计数
    final keepAlive = KeepAliveStore();
    await keepAlive.setNext(p, null);
    await keepAlive.setFailureCount(p, 0);
    await keepAlive.setLastNotifiedAt(p, null);
    // 压缩日志，抹掉磁盘上残留的凭据帧
    await _box!.compact();
  }

  /// 记录用户登录后实际停留的页面地址，供连接器复用（避免猜测各平台的订单页 URL）
  Future<void> saveEntryUrl(String platform, String url) async {
    if (url.trim().isEmpty) return;
    await _ensureInit();
    await _box!.put('${platform.toLowerCase()}_entry_url', url.trim());
  }

  String? getEntryUrl(String platform) {
    final box = _safeBox;
    if (box == null || !box.isOpen) return null;
    return box.get('${platform.toLowerCase()}_entry_url') as String?;
  }

  DateTime? getBoundTime(String platform) {
    final box = _safeBox;
    if (box == null || !box.isOpen) return null;
    final ms = box.get('${platform.toLowerCase()}_updated_at') as int?;
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  // ── 已删除/已忽略包裹黑名单（防重新同步时死灰复燃） ──
  static const String _kBlacklistKey = 'deleted_package_blacklist_v1';
  static final Set<String> _blacklistCache = <String>{};
  static bool _blacklistLoaded = false;

  void _ensureBlacklistLoaded() {
    if (_blacklistLoaded) return;
    try {
      final box = _safeBox;
      if (box != null && box.isOpen) {
        final list = box.get(_kBlacklistKey);
        if (list is List) {
          _blacklistCache.addAll(list.map((e) => e.toString()));
        }
        _blacklistLoaded = true;
      }
    } catch (e) {
      debugPrint('[AuthStore] load blacklist error: $e');
    }
  }

  /// 将已删除包裹的 ID 与有效单号加入黑名单
  void addToBlacklist(String id, {String? trackingNumber}) {
    _ensureBlacklistLoaded();
    final cleanId = id.trim();
    if (cleanId.isNotEmpty) _blacklistCache.add(cleanId);
    final cleanTracking = trackingNumber?.trim();
    if (cleanTracking != null && cleanTracking.isNotEmpty && !cleanTracking.contains('-')) {
      _blacklistCache.add(cleanTracking);
    }
    _saveBlacklist();
  }

  /// 移除黑名单记录（用户主动重新添加或恢复时使用）
  void removeFromBlacklist(String id, {String? trackingNumber}) {
    _ensureBlacklistLoaded();
    _blacklistCache.remove(id.trim());
    if (trackingNumber != null) {
      _blacklistCache.remove(trackingNumber.trim());
    }
    _saveBlacklist();
  }

  /// 检查包裹 ID 或运单号是否在黑名单中
  bool isBlacklisted(String id, {String? trackingNumber}) {
    _ensureBlacklistLoaded();
    final cleanId = id.trim();
    if (cleanId.isNotEmpty && _blacklistCache.contains(cleanId)) return true;
    final cleanTracking = trackingNumber?.trim();
    if (cleanTracking != null && cleanTracking.isNotEmpty && _blacklistCache.contains(cleanTracking)) {
      return true;
    }
    return false;
  }

  /// 获取当前所有已黑名单的标识集合
  Set<String> getBlacklist() {
    _ensureBlacklistLoaded();
    return Set.unmodifiable(_blacklistCache);
  }

  /// 清空黑名单缓存与持久化数据（测试或用户重置时使用）
  void clearBlacklist() {
    _blacklistCache.clear();
    _blacklistLoaded = true;
    _saveBlacklist();
  }

  void _saveBlacklist() {
    try {
      final box = _safeBox;
      if (box != null && box.isOpen) {
        box.put(_kBlacklistKey, _blacklistCache.toList());
      }
    } catch (e) {
      debugPrint('[AuthStore] save blacklist error: $e');
    }
  }
}
