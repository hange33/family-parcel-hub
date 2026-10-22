/// 保活调度状态持久化
///
/// 为什么需要落盘：保活服务原先把「上次保活时间 / 失败次数 / 下次保活时间」放在内存里，
/// 进程重启即清零，于是每次冷启动都会立刻对全部已绑定平台重发一轮心跳。
/// 把 `next_keep_alive_at` 落盘后，冷启动时闸门依然生效。
///
/// 只存时间戳与计数（不含任何凭据），因此与 `sync_history` 一样使用明文 box。
///
/// 前后台两个 isolate 会各自打开同一个 box，写入策略据此约定：
/// - 后台 worker 只做**单 key 标量**写入（幂等、last-writer-wins）；
/// - 需要 read-modify-write 的 `history` **只由主 isolate 写**；
/// - 前台启动时 [loadIntoCache] 以磁盘为准覆盖内存，天然与后台写入收敛。
library;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/models/keep_alive_state.dart';
import '../../core/models/platform_ids.dart';

/// 保活状态 Box 名称（在 main.dart 与后台 worker 中预先打开）
const String kKeepAliveBox = 'keep_alive_state';

class KeepAliveStore {
  static const String _boxName = kKeepAliveBox;

  /// 当前 schema 版本，便于后续迁移
  static const int _schemaVersion = 1;

  Box? _box;

  // 高频读路径的内存缓存：同步 getter 不应依赖 box 是否已打开
  bool _enabled = true;
  final Map<String, bool> _platformEnabled = {};
  final Map<String, DateTime> _nextCache = {};
  final Map<String, DateTime> _lastCache = {};
  final Map<String, int> _failureCache = {};
  final Map<String, DateTime> _notifiedCache = {};
  KeepAliveHistory _history = KeepAliveHistory.empty;

  static String _nextKey(String p) => '${p.toLowerCase()}_next_keep_alive_at';
  static String _lastKey(String p) => '${p.toLowerCase()}_last_keep_alive_at';
  static String _failureKey(String p) => '${p.toLowerCase()}_failure_count';
  static String _enabledKey(String p) => '${p.toLowerCase()}_enabled';
  static String _notifiedKey(String p) => '${p.toLowerCase()}_last_notify_expired_at';

  /// 启动时预打开存储（main.dart 与后台 worker 各调用一次）
  static Future<void> initialize() async {
    if (!Hive.isBoxOpen(_boxName)) {
      try {
        await Hive.openBox(_boxName);
      } catch (e) {
        debugPrint('[KeepAliveStore] open box failed: $e');
      }
    }
  }

  Box? get _safeBox {
    if (_box != null && _box!.isOpen) return _box;
    if (Hive.isBoxOpen(_boxName)) {
      _box = Hive.box(_boxName);
      return _box;
    }
    return null;
  }

  Future<void> _ensureInit() async {
    if (_safeBox != null) return;
    try {
      _box = Hive.isBoxOpen(_boxName)
          ? Hive.box(_boxName)
          : await Hive.openBox(_boxName);
    } catch (e) {
      debugPrint('[KeepAliveStore] ensureInit failed: $e');
    }
  }

  /// 从磁盘预热内存缓存
  ///
  /// 这是前后台两个 isolate 收敛的手段：无论后台写了什么，前台启动时以磁盘为准。
  Future<void> loadIntoCache() async {
    await _ensureInit();
    final box = _safeBox;
    if (box == null) return;

    DateTime? readTime(String key) {
      final ms = box.get(key);
      return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    }

    _enabled = box.get('enabled') as bool? ?? true;

    _platformEnabled.clear();
    _nextCache.clear();
    _lastCache.clear();
    _failureCache.clear();
    _notifiedCache.clear();

    for (final platform in kPlatformIds) {
      _platformEnabled[platform] = box.get(_enabledKey(platform)) as bool? ?? true;
      final next = readTime(_nextKey(platform));
      if (next != null) _nextCache[platform] = next;
      final last = readTime(_lastKey(platform));
      if (last != null) _lastCache[platform] = last;
      _failureCache[platform] = box.get(_failureKey(platform)) as int? ?? 0;
      final notified = readTime(_notifiedKey(platform));
      if (notified != null) _notifiedCache[platform] = notified;
    }

    final rawHistory = box.get('history');
    _history = rawHistory is List
        ? KeepAliveHistory.fromJson(rawHistory)
        : KeepAliveHistory.empty;
  }

  // ── 读取（内存缓存，同步） ──

  bool get enabled => _enabled;

  bool platformEnabled(String platform) => _platformEnabled[platform.toLowerCase()] ?? true;

  DateTime? nextAt(String platform) => _nextCache[platform.toLowerCase()];

  DateTime? lastAt(String platform) => _lastCache[platform.toLowerCase()];

  int failureCount(String platform) => _failureCache[platform.toLowerCase()] ?? 0;

  DateTime? lastNotifiedAt(String platform) => _notifiedCache[platform.toLowerCase()];

  KeepAliveHistory get history => _history;

  // ── 写入 ──

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _ensureInit();
    await _safeBox?.put('enabled', value);
  }

  Future<void> setPlatformEnabled(String platform, bool value) async {
    final p = platform.toLowerCase();
    _platformEnabled[p] = value;
    await _ensureInit();
    await _safeBox?.put(_enabledKey(p), value);
  }

  /// 设置下次保活时间；传 null 表示清除闸门（下次检查立即放行）
  Future<void> setNext(String platform, DateTime? time) async {
    final p = platform.toLowerCase();
    await _ensureInit();
    if (time == null) {
      _nextCache.remove(p);
      await _safeBox?.delete(_nextKey(p));
      return;
    }
    _nextCache[p] = time;
    await _safeBox?.put(_nextKey(p), time.millisecondsSinceEpoch);
  }

  /// 清除闸门：刚绑定 / 刚恢复登录态时调用，让保活尽快真实发生一次
  Future<void> clearNext(String platform) => setNext(platform, null);

  Future<void> setLast(String platform, DateTime time) async {
    final p = platform.toLowerCase();
    _lastCache[p] = time;
    await _ensureInit();
    await _safeBox?.put(_lastKey(p), time.millisecondsSinceEpoch);
  }

  Future<void> setFailureCount(String platform, int count) async {
    final p = platform.toLowerCase();
    _failureCache[p] = count;
    await _ensureInit();
    await _safeBox?.put(_failureKey(p), count);
  }

  /// 记录失效通知时间；传 null 清除（登录态恢复时调用，使下个失效周期可再通知）
  Future<void> setLastNotifiedAt(String platform, DateTime? time) async {
    final p = platform.toLowerCase();
    await _ensureInit();
    if (time == null) {
      _notifiedCache.remove(p);
      await _safeBox?.delete(_notifiedKey(p));
      return;
    }
    _notifiedCache[p] = time;
    await _safeBox?.put(_notifiedKey(p), time.millisecondsSinceEpoch);
  }

  /// 追加一条保活历史（仅主 isolate 调用）
  Future<void> appendHistory(KeepAliveRecord record, {int cap = KeepAliveHistory.defaultCap}) async {
    _history = _history.appended(record, cap: cap);
    await _ensureInit();
    await _safeBox?.put('history', _history.toJson());
  }

  /// 写入 schema 版本（首次初始化时）
  Future<void> ensureSchemaVersion() async {
    await _ensureInit();
    final box = _safeBox;
    if (box == null) return;
    if (box.get('schema_version') != _schemaVersion) {
      await box.put('schema_version', _schemaVersion);
    }
  }
}
