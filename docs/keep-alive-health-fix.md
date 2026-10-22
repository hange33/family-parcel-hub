# 保活机制健康状态判断修复

## 问题描述

用户报告：京东登录失效了一天，保活机制显示"健康"，失败次数 3，但保活时间不到 2 小时。

## 根本原因

### 1. 健康状态只看 Cookie 年龄，忽略失败次数
```dart
// 修复前 - lib/platform/keep_alive/keep_alive_service.dart:169
'health': KeepAliveScheduler.getCookieHealthDescription(cookieAge)
```
即使心跳连续失败 3 次、登录已失效，只要 Cookie 是 3 天前绑定的，仍显示"健康"。

### 2. 京东心跳不可靠
```dart
// 修复前 - lib/platform/keep_alive/platform_heartbeat.dart:123
final response = await http.head(...)  // HEAD 请求无响应体
if (response.statusCode == 200) {
  return HeartbeatResult.success();  // 200 不代表登录有效
}
```
HEAD 请求无法获取响应体验证登录态，200 状态码可能是"请登录"页面。

### 3. 失败后不标记登录态失效
```dart
// 修复前 - lib/platform/keep_alive/keep_alive_service.dart:151
if (_failureCount[platform]! >= 3) {
  debugPrint('login expired');
  // TODO: 通知 ConnectorManager 登录态失效  ❌ 只打印日志
}
```

### 4. 固定 12 小时间隔，不响应 Cookie 老化
```dart
// 修复前 - lib/platform/keep_alive/keep_alive_service.dart:54
_timer = Timer.periodic(const Duration(hours: 12), (_) { ... });
```
`KeepAliveScheduler.calculateInterval()` 计算的 4-24 小时动态间隔完全没用上。

### 5. `shouldSkip()` 过度保守
```dart
// lib/platform/keep_alive/keep_alive_scheduler.dart:52
if (timeSinceKeepAlive.inHours < 2) {
  return true;  // 2 小时内跳过
}
```
即使定时器每 12 小时触发一次，如果距上次保活不到 2 小时也会跳过。

## 修复方案

### 1. 增强健康状态判断（综合失败次数）✅

**文件**: [lib/platform/keep_alive/keep_alive_service.dart](../lib/platform/keep_alive/keep_alive_service.dart)

```dart
Map<String, dynamic> getStatus(String platform) {
  final failureCount = _failureCount[platform] ?? 0;
  final isExpired = _authStore.isExpired(platform);
  
  // 优先级：失效标记 > 失败次数 > Cookie 年龄
  String health;
  if (isExpired) {
    health = '失效';
  } else if (failureCount >= 3) {
    health = '失效';
  } else if (failureCount >= 1) {
    health = '不稳定';
  } else if (cookieAge != null) {
    health = KeepAliveScheduler.getCookieHealthDescription(cookieAge);
  } else {
    health = 'unknown';
  }
  
  return {
    'health': health,
    'failureCount': failureCount,
    'isExpired': isExpired,
    ...
  };
}
```

### 2. 改进京东心跳（GET + 响应验证）✅

**文件**: [lib/platform/keep_alive/platform_heartbeat.dart](../lib/platform/keep_alive/platform_heartbeat.dart)

```dart
class HeartbeatResult {
  final bool success;
  final String? errorMessage;
  final DateTime timestamp;
  final bool isAuthFailure;  // 新增：区分登录失效 vs 网络错误
}

Future<HeartbeatResult> performHeartbeat(String cookies) async {
  // 从 HEAD 改为 GET
  final response = await http.get(
    Uri.parse('https://wqs.jd.com/order/orderlist_jdm.shtml'),
    headers: {...},
  );
  
  if (response.statusCode == 200) {
    final body = response.body;
    
    // 检查登录态失效标识
    if (body.contains('请登录') ||
        body.contains('login.m.jd.com') ||
        body.contains('"isLogin":false')) {
      return HeartbeatResult.failure(
        '登录态已失效（响应要求登录）',
        isAuthFailure: true,  // 明确标记为登录失效
      );
    }
    
    // 检查正常订单数据
    if (body.contains('orderList') || body.contains('订单')) {
      return HeartbeatResult.success();
    }
  } else if (response.statusCode == 401 || response.statusCode == 403) {
    return HeartbeatResult.failure(
      '登录态已失效（HTTP ${response.statusCode}）',
      isAuthFailure: true,
    );
  }
  
  // 其他错误视为网络问题
  return HeartbeatResult.failure('HTTP ${response.statusCode}', isAuthFailure: false);
}
```

### 3. 失败后标记登录态失效 ✅

**文件**: [lib/platform/keep_alive/keep_alive_service.dart](../lib/platform/keep_alive/keep_alive_service.dart)

```dart
Future<void> _performHeartbeatForPlatform(...) async {
  final result = await heartbeat.performHeartbeat(cookies);
  
  if (result.success) {
    _failureCount[platform] = 0;
    await _authStore.setExpired(platform, false);  // 清除失效标记
  } else {
    // 明确的登录失效，立即标记
    if (result.isAuthFailure) {
      await _authStore.setExpired(platform, true);
      _failureCount[platform] = 3;
    } else {
      // 网络错误，累积失败计数
      _failureCount[platform] = (_failureCount[platform] ?? 0) + 1;
      
      if (_failureCount[platform]! >= 3) {
        await _authStore.setExpired(platform, true);
      }
    }
  }
}
```

### 4. 重新绑定清除失效标记 ✅

**文件**: [lib/platform/storage/platform_auth_store.dart](../lib/platform/storage/platform_auth_store.dart)

```dart
Future<void> saveCookies(String platform, String cookies) async {
  // ... 现有逻辑 ...
  await setExpired(p, false);  // 清除旧的失效标记
}
```

### 5. 动态保活间隔调度 ✅

**文件**: [lib/platform/keep_alive/keep_alive_service.dart](../lib/platform/keep_alive/keep_alive_service.dart)

```dart
// 新增字段
final Map<String, DateTime> _nextKeepAliveTime = {};

void start() {
  // 每小时检查一次（而非固定 12 小时）
  _timer = Timer.periodic(const Duration(hours: 1), (_) {
    _performKeepAlive();
  });
}

Future<void> _performKeepAlive() async {
  for (final platform in platforms) {
    final cookieAge = ...;
    
    // 根据 Cookie 年龄计算动态间隔
    final interval = KeepAliveScheduler.calculateInterval(cookieAge);
    
    // 检查是否到了下次保活时间
    final nextTime = _nextKeepAliveTime[platform];
    if (nextTime != null && now.isBefore(nextTime)) {
      debugPrint('Skip $platform: next keep-alive in ${remaining.inMinutes} min');
      continue;
    }
    
    await _performHeartbeatForPlatform(platform, cookies, cookieAge);
    
    // 计算下次保活时间
    _nextKeepAliveTime[platform] = KeepAliveScheduler.calculateNextTime(interval);
  }
}
```

## 保活间隔策略

根据 Cookie 年龄动态调整：
- **0-3 天**：24 小时（新鲜期，低频维护）
- **4-7 天**：12 小时（中期，适度保活）
- **8-10 天**：6 小时（临期，积极保活）
- **11+ 天**：4 小时（危险期，高频保活）

定时器每 1 小时检查一次，各平台独立计算下次保活时间。

## 验证方法

### 1. 模拟登录失效
手动删除京东 Cookie 中的 `pt_key` 字段。

### 2. 触发保活
```dart
final service = ref.read(keepAliveServiceProvider);
await service.performManualKeepAlive();
```

### 3. 检查状态
```dart
final status = service.getStatus('jd');
print(status['health']);       // 应显示 "失效"
print(status['failureCount']); // 应为 3
print(status['isExpired']);    // 应为 true
```

### 4. 重新绑定
在登录页重新授权后，`isExpired` 应自动清除。

## 影响范围

- ✅ 健康状态现在准确反映登录态
- ✅ 京东心跳更可靠（GET + 响应体验证）
- ✅ 失败后立即标记失效状态
- ✅ 保活间隔根据 Cookie 年龄动态调整
- ✅ 重新绑定自动清除失效标记

## 相关文件

- [lib/platform/keep_alive/keep_alive_service.dart](../lib/platform/keep_alive/keep_alive_service.dart)
- [lib/platform/keep_alive/platform_heartbeat.dart](../lib/platform/keep_alive/platform_heartbeat.dart)
- [lib/platform/keep_alive/keep_alive_scheduler.dart](../lib/platform/keep_alive/keep_alive_scheduler.dart)
- [lib/platform/storage/platform_auth_store.dart](../lib/platform/storage/platform_auth_store.dart)
