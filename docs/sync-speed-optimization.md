# 同步速度优化方案

## 📊 当前瓶颈分析

### 1. 串行等待问题

**当前实现**：
- ✅ 三个平台**并发执行**（`Future.wait`）
- ❌ 但每个平台内部是**串行处理**：
  - 淘宝：先拉订单列表 → 再逐个请求物流详情（N 个订单 = N+1 次请求）
  - 京东：加载订单页 → 等待页面渲染 → 逐个拉取物流详情
  - 拼多多：拉订单列表 → 逐个打开详情页抓取

**时间消耗**（典型场景）：
```
淘宝（5个订单）: 2s（列表）+ 5×1.5s（详情）= 9.5s
京东（3个订单）: 3s（页面）+ 3×2s（详情）= 9s
拼多多（4个订单）: 2s（列表）+ 4×3s（详情）= 14s

总耗时：max(9.5s, 9s, 14s) = 14s（并发）
理论最优：2s（最慢列表）+ 3s（最慢单个详情）= 5s
```

### 2. WebView 加载延迟

**问题**：
- 每个平台都需要加载完整 WebView 页面
- DOM 渲染 + JavaScript 执行 = 2-3 秒
- Cookie 注入 + 网络钩子安装 = 额外延迟

**示例**（拼多多）：
```dart
await controller.loadRequest(...)  // 1-2s
await _awaitPageInteractive()      // 0.5-1s
await _clickViewLogistics()        // 1-2s
await _awaitExpressTimelineText()  // 1-3s
```

### 3. 已签收订单重复请求

**问题**：
- 淘宝已有优化（跳过已签收订单详情）
- 但京东/拼多多没有此优化
- 每次同步都重新拉取所有订单详情

### 4. 缺少增量同步

**问题**：
- 每次都全量拉取所有订单
- 没有基于时间戳的增量更新
- 浪费在已知无变化的订单上

---

## 🚀 优化方案

### 方案 A：订单详情并发拉取（立即见效）

**原理**：订单详情之间互不依赖，可以并发请求

**实施位置**：
1. `taobao_connector.dart` - 淘宝物流详情并发
2. `jd_connector.dart` - 京东物流详情并发
3. `pdd_connector.dart` - 拼多多订单详情并发

**预期提升**：
- 淘宝：9.5s → 2s（列表）+ 1.5s（最慢详情）= **3.5s**（63% ↓）
- 京东：9s → 3s（页面）+ 2s（最慢详情）= **5s**（44% ↓）
- 拼多多：14s → 2s（列表）+ 3s（最慢详情）= **5s**（64% ↓）
- **总耗时：5s**（64% ↓）

**技术实现**：

```dart
// 淘宝：并发拉取物流详情
final detailFutures = orders.map((order) async {
  return await _fetchSsrLogistics(client, cookies, order.orderId);
}).toList();

final details = await Future.wait(detailFutures);
```

**风控风险**：⚠️ 中等
- 短时间大量请求可能触发风控
- 建议：限制并发数（3-5 个），使用信号量控制

---

### 方案 B：WebView 预热与复用（中等改造）

**原理**：提前创建 WebView，复用同一实例

**实施**：
1. App 启动时预创建 WebView 实例
2. 同步时直接复用，避免重复初始化
3. 同步完成后保持实例（不销毁）

**预期提升**：
- 节省 WebView 初始化时间：**1-2s**
- 淘宝/拼多多受益最大

**技术实现**：

```dart
class PddH5Connector {
  static WebViewController? _sharedController;
  
  Future<void> _ensureController() async {
    if (_sharedController != null) {
      _controller = _sharedController;
      return;
    }
    // 初始化新实例
    _sharedController = WebViewController()...;
    _controller = _sharedController;
  }
}
```

**风控风险**：✅ 低

---

### 方案 C：智能跳过已同步订单（易实施）

**原理**：记录上次同步时间，只拉取新订单

**实施**：
1. 扩展 `PlatformAuthStore` 记录最近同步时间
2. 连接器传递 `since` 参数（如果平台支持）
3. 本地过滤：跳过 24 小时内已拉取且未变化的订单

**预期提升**：
- 第二次及后续同步：**50-80% ↓**
- 仅拉取有变化的订单

**技术实现**：

```dart
// 本地过滤（所有平台通用）
final localPackages = _getLocalPackages();
final recentSynced = localPackages
    .where((p) => DateTime.now().difference(p.addedAt).inHours < 24)
    .map((p) => p.orderId)
    .toSet();

// 跳过最近同步过的订单
final needFetchOrders = orders
    .where((o) => !recentSynced.contains(o.orderId))
    .toList();
```

**风控风险**：✅ 低

---

### 方案 D：早期数据流式返回（用户体验优化）

**原理**：不等所有平台同步完成，先返回部分数据

**当前实现**：
- ✅ 已支持 `onEarlyProgress` 回调
- ✅ 首个包裹到达时触发 UI 更新

**可优化**：
- 改为逐个包裹 `yield`，而不是批量返回
- UI 实时更新，用户立即看到结果

**预期提升**：
- **感知速度 ↑ 80%**（实际同步时间不变，但用户感觉更快）

**技术实现**：

```dart
Stream<Package> streamSync() async* {
  final orders = await _fetchOrderList();
  
  // 当前：等待所有详情后才返回
  // final packages = await Future.wait(...);
  // for (final pkg in packages) yield pkg;
  
  // 优化：逐个返回
  for (final order in orders) {
    final pkg = await _fetchDetail(order);
    yield pkg; // 立即返回，UI 立即更新
  }
}
```

**风控风险**：✅ 低

---

### 方案 E：缓存物流轨迹（长期优化）

**原理**：缓存不变的轨迹节点，只拉取增量

**实施**：
1. 存储每个包裹的最新轨迹哈希
2. 只请求有变化的包裹详情
3. 拼多多已实现（`_timelineCache`），推广到其他平台

**预期提升**：
- 已到达包裹：**跳过详情请求**
- 节省 50-70% 网络请求

**风控风险**：✅ 低

---

## 📋 推荐实施顺序

### Phase 1：立即见效（1-2 天）

1. **方案 A**: 订单详情并发拉取（**重点**）
   - 优先实施淘宝（最多订单）
   - 限制并发数为 3-5
   - 预期提升：60%+

2. **方案 D**: 流式返回数据
   - 改造现有 `streamSync`
   - 用户体验立即改善

### Phase 2：中期优化（3-5 天）

3. **方案 C**: 智能跳过已同步订单
   - 减少重复请求
   - 第二次同步速度 ↑ 50%

4. **方案 B**: WebView 预热
   - 节省初始化时间
   - 需要测试生命周期管理

### Phase 3：长期优化（1-2 周）

5. **方案 E**: 轨迹缓存推广
   - 京东/淘宝也支持缓存
   - 最大化减少请求

---

## ⚠️ 风控防护

### 并发控制

```dart
class ConcurrentLimiter {
  final int maxConcurrent;
  int _running = 0;
  final List<Completer> _queue = [];
  
  Future<T> run<T>(Future<T> Function() task) async {
    while (_running >= maxConcurrent) {
      final completer = Completer();
      _queue.add(completer);
      await completer.future;
    }
    
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_queue.isNotEmpty) {
        _queue.removeAt(0).complete();
      }
    }
  }
}
```

### 请求间隔

```dart
// 在并发请求之间添加随机延迟
await Future.delayed(Duration(
  milliseconds: 100 + Random().nextInt(200) // 100-300ms
));
```

### 失败重试

```dart
Future<T> retryWithBackoff<T>(
  Future<T> Function() task,
  {int maxRetries = 3}
) async {
  for (int i = 0; i < maxRetries; i++) {
    try {
      return await task();
    } catch (e) {
      if (i == maxRetries - 1) rethrow;
      await Future.delayed(Duration(seconds: 1 << i)); // 指数退避
    }
  }
  throw Exception('unreachable');
}
```

---

## 📊 预期效果总结

| 方案 | 实施难度 | 风控风险 | 提升幅度 | 推荐优先级 |
|-----|---------|---------|---------|-----------|
| A. 详情并发 | ⭐⭐ | ⚠️ 中 | **60-70%** | 🔥 P0 |
| B. WebView 预热 | ⭐⭐⭐ | ✅ 低 | 10-20% | P1 |
| C. 智能跳过 | ⭐ | ✅ 低 | 50-80%（二次同步） | 🔥 P0 |
| D. 流式返回 | ⭐ | ✅ 低 | 感知速度 ↑80% | 🔥 P0 |
| E. 轨迹缓存 | ⭐⭐ | ✅ 低 | 30-50% | P1 |

**综合提升**（Phase 1 完成后）：
- 首次同步：**14s → 5s**（64% ↓）
- 二次同步：**14s → 2-3s**（80% ↓）
- 用户感知：**立即看到结果**

---

## 🧪 测试计划

### 性能测试

1. **同步时间对比**
   - 优化前 vs 优化后
   - 不同订单数量（1/5/10/20 个）
   - 不同网络条件（WiFi/4G/3G）

2. **并发压力测试**
   - 测试并发数上限（不触发风控）
   - 记录成功率与响应时间

3. **长期稳定性**
   - 连续 7 天每天同步 10 次
   - 观察是否触发风控
   - 记录失败率

### 功能回归测试

- ✅ 所有测试套件通过
- ✅ 包裹合并逻辑正确
- ✅ 物流轨迹完整
- ✅ 通知正常触发

---

## 💡 实施建议

### 最小化风险

1. **分批上线**：
   - 先优化淘宝（数据源最稳定）
   - 观察 2-3 天无问题后推广到京东/拼多多

2. **灰度控制**：
   - 添加 Feature Flag 控制并发
   - 异常时自动降级到串行模式

3. **监控告警**：
   - 记录同步时间到日志
   - 失败率 > 10% 时触发降级

### 用户反馈

- 在设置页显示同步统计
- 记录平均同步时间
- 收集用户反馈

---

**下一步**：开始实施 Phase 1（方案 A + D），预计 1-2 天完成，提升 60%+ 速度。
