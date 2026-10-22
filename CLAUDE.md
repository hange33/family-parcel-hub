# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

现代化中文快递包裹追踪与聚合管理 Android 应用，使用 Flutter 构建。聚合拼多多、京东、淘宝等多电商平台真实物流，结合在途优先 UI 与官方级物流时间轴，解决包裹分散、双端登录互踢、取件码格式不一等痛点。

- **语言**: Dart 3.6+, Flutter 3.6+
- **平台**: Android (Min SDK 24, Target SDK 34)
- **状态管理**: Riverpod
- **存储**: Hive (NoSQL)
- **网络**: http + webview_flutter (电商平台容器与 Cookie 捕获)

## Common Commands

```bash
# 开发运行（支持物理机与模拟器）
flutter run

# 代码静态检查
flutter analyze lib/

# 运行测试套件
flutter test

# 运行特定测试文件
flutter test test/package_identity_test.dart

# Hive TypeAdapter 代码生成（修改存储模型后）
flutter pub run build_runner build --delete-conflicting-outputs

# 构建 Release APK（通用包，含全部 ABI）
flutter build apk --release

# 按 CPU 架构分包（体积更小，用于分发）
flutter build apk --release --split-per-abi

# 提交前扫描真实订单号 / 手机号等 PII，防止混入仓库
./tools/check_no_pii.sh
```

生产物位于 `build/app/outputs/flutter-apk/`（`app-release.apk`，或分包后的 `app-<abi>-release.apk`）。

`tools/dev_run.dart` 是本地热重载宿主（不参与 App 运行）：后台常驻 `flutter run`，通过写入 `build/devcmd.txt`（`r` 热重载 / `R` 热重启）驱动其 stdin，省去重装 APK。默认设备 id 在脚本内硬编码，可传参覆盖。

## Architecture: Strict Four-Layer Unidirectional Dependency

项目严格遵循**四层单向依赖架构**，保障模块解耦与跨平台复用：

```
       ┌────────┐
       │   ui/  │  渲染层：Flutter 页面、Riverpod Providers、Theme、组件
       └───┬────┘
           │
           ├───────────────┐
           ▼               ▼
       ┌────────┐      ┌───────────┐
       │  app/  │      │ platform/ │  适配层：Hive 存储、电商连接器、通知、WebView、后台服务
       └───┬────┘      └─────┬─────┘
           │                 │
           └────────┬────────┘
                    ▼
               ┌────────┐
               │ core/  │  纯 Dart 核心逻辑（冻结层）：不可变模型、状态机、解析器
               └────────┘
```

### **CRITICAL: `lib/core/` Purity Constraint**

`lib/core/` 必须保持为**纯 Dart 代码**：
- ❌ 严禁导入 Flutter SDK (`package:flutter/`)
- ❌ 严禁导入平台驱动 (Hive, http, webview)
- ❌ 严禁导入状态管理 (Riverpod, Provider)
- ✅ 只允许纯 Dart 依赖 (`dart:core`, `dart:convert`, `package:equatable`)

**目的**: 核心计算与业务逻辑具备 100% 可测试性，独立于渲染与平台。

### Key Layers

#### 1. `lib/core/` — Pure Dart Business Logic

**子模块**:
- `models/`: 不可变领域模型 (`Package`, `PackageStatus`, `CourierType`, `OrderMeta`, `PickupInfo`, `TrackingTrace`)
- `engine/`: 核心状态机与推断引擎
  - `package_identity.dart`: 包裹身份判定、打码单号匹配、合并规则（P11-b: 淘宝打码单号与菜鸟完整单号合并逻辑）
  - `logistics_status_engine.dart`: 基于轨迹时间流推导 `PackageStatus`、物流稳定性与同步间隔
  - `timeline_merge.dart`: 多源轨迹时间线合并与去重
  - `timeline_view.dart`: 把轨迹模型整理为可渲染的时间轴视图模型
  - `hero_card_engine.dart`: 纯 Dart 计算 Hero 卡片的结构化决策（计数、紧急度评分、情绪状态）
  - `hero_card_state.dart`: Hero 决策结果的数据结构（`HeroCardState`、`HeroBadgeType`、`HeroEmotionState` 等）
  - `keep_alive_plan.dart`: 保活调度决策（按 Cookie 年龄分档、时间可注入、可单测）
- `parser/`: 文本提取器与词典（`extractors.dart` 提取快递公司/运单号/取件码/状态，`courier_dictionary.dart` 承运商别名，`taobao_trace_parser.dart` 淘宝轨迹，`trace_time.dart` 时间解析，`text_preprocessor.dart` 预处理）
- `sanitizer/`: 文本归一化与清洗（噪声词典、行分类、商品名清洗）
- `utils/`: 通用文本归一化（`text_normalizer.dart`）
- `debug/`: 调试追踪与性能度量（`debug_trace.dart`、`metrics.dart`，不污染生产代码）

> `models/` 下的 `courier_type.dart` 是**未被引用的历史遗留**：实际使用的 `CourierType` / `UrgencyLevel` 枚举定义在 `models/package.dart`。新增代码不要导入 `courier_type.dart`。

**不可变模型设计**:
```dart
class Package {
  final String id;             // 包裹唯一标识 (PDD_<订单号>, JD_<订单号>, TB_<订单号>, CN_<运单号>)
  final String trackingNumber; // 运单号（可能为打码单号如 YT12*******5678）
  final CourierType courier;
  final PackageStatus status;
  final String? pickupCode;    // 取件码
  final String? stationName;   // 自提点/驿站名
  final String? goodsName;
  final String? goodsImageUrl;
  final String? rawTimelineJson; // 序列化的物流轨迹 JSON
  final DateTime? pickedUpAt;  // 用户手动标记已取的时间（同步从不清空此字段）
  // ... 使用 copyWith() 实现不可变更新
}
```

#### 2. `lib/platform/` — Infrastructure & Platform Adapters

**子模块**:
- `connectors/`: 电商平台数据连接器
  - `platform_connector.dart`: 抽象接口 (`PlatformConnector`)
  - `pdd_connector.dart`: 拼多多 (支持内置 H5 商城、防互踢)
  - `jd_connector.dart`: 京东 (过滤外卖闪送订单)
  - `taobao_connector.dart`: 淘宝/天猫 (MTOP API + 菜鸟驿站)
  - `connector_manager.dart`: 多平台同步调度器
  - `taobao_sync_rules.dart`: 淘宝同步策略（打码单号合并、已签收订单跳过请求）
  - `*_trace_parser.dart`: 各平台物流轨迹 JSON 解析器（pdd / jd / taobao）
  - `jd_delivery_filter.dart`: 过滤京东外卖/秒送等即时订单
  - `concurrent_limiter.dart`: 并发控制工具（ThrottledExecutor，限制并发数与随机延迟）
  - `sync_optimizer.dart`: 智能跳过已同步订单（24 小时内、已完成状态）
  - `sync_diagnostics.dart`: 同步诊断数据收集
  - `mock_connector.dart`: 开发/测试用的模拟连接器
- `storage/`: 持久化层
  - `hive_package.dart`: Hive 序列化包装器 (`HivePackage` ↔ `Package`)
  - `hive_adapters.dart`: Hive TypeAdapter 注册
  - `platform_auth_store.dart`: Cookie 与凭据持久化
  - `keep_alive_store.dart`: 保活状态落盘（`keep_alive_state` box）
- `webview/`: `platform_cookie.dart` WebView Cookie 桥接
- `notification/`: 本地推送通知
  - `notification_adapter.dart`: 到件通知、24 小时提醒调度
- `sync/`: 后台同步服务
  - `background_sync_service.dart`: 自适应后台同步（根据包裹状态动态调整间隔）
  - `sync_history_manager.dart`: 同步历史记录管理（用于智能跳过）
- `keep_alive/`: 电商平台保活机制
  - `keep_alive_service.dart`: 平台保活服务（按闸门与冷却决定是否发心跳，结果落盘）
  - `keep_alive_controller.dart`: Riverpod `Notifier`，暴露可 watch 的 `KeepAliveSnapshot`
  - `platform_heartbeat.dart`: 淘宝/京东心跳实现（纯 HTTP，可后台运行）
  - `pdd_connector_heartbeat.dart`: 拼多多心跳，委托 `PddH5Connector` 的常驻 WebView
  - `keep_alive_notifier.dart`: 失效提醒收口（去重标记仅在发送成功后落盘）
  - `keep_alive_worker.dart`: WorkManager 后台 isolate，App 被杀后仍可续期
  - `taobao_token_refresher.dart`: 淘宝 token 续期
  - 调度决策已下沉到 `lib/core/engine/keep_alive_plan.dart`（原 `keep_alive_scheduler.dart` 已删除）

**关键设计**:
- 每个 `PlatformConnector` 通过 `Stream<Package> streamSync()` 流式产出包裹数据
- `taobao_connector.dart` 包含打码单号补全与菜鸟优先级逻辑（P11-b 后续）
- 三个平台同步已实现并发优化（3 并发，100-400ms 随机延迟，防风控）

#### 3. `lib/ui/` — Presentation Layer

**子模块**:
- `providers/`: Riverpod 状态提供者
  - `package_provider.dart`: `PackageListNotifier` (包裹列表状态管理、合并逻辑、Hive 持久化)
- `screens/`:
  - `home/`: 在途优先主页 (`home_screen.dart`)，子组件在 `widgets/`（`hero_stats_dashboard.dart` 仪表盘、`animated_package_list.dart` 列表增删重排动画、`modern_package_card.dart` 卡片、`completed_packages_sheet.dart` 已完成归档抽屉、`tracking_timeline_sheet.dart` 物流时间轴抽屉）
  - `pdd/`: 拼多多内置移动端商城容器 (`PddWebScreen`)
  - `login/`: 平台账号授权与 Cookie 捕获
  - `settings/`: 平台绑定管理、保活状态 (`keep_alive_status_screen.dart`)、诊断 (`diagnostics_screen.dart`)、后台同步测试工具 (`background_sync_test_screen.dart`，`kDebugMode` 门控，Release 被 tree-shaking 移除)
- `theme/`: 主题与动效（`app_theme.dart`、`motion.dart` 全局动效令牌、`status_extension.dart` 状态配色）
- `components/`: 通用组件（弹簧卡片 `spring_card.dart`、平台徽章、`hero_pickup_badge.dart` 取件码徽章、`tracking_timeline.dart`、`status_pill.dart`、`staggered_entrance.dart`）

> 另有一层 `lib/app/`：应用级决策编排（`hero_decision.dart` 把 core 的 `HeroCardState` 映射为带图标/颜色的 Flutter 决策）。它依赖 Flutter，是 `core/`（纯 Dart）与 `ui/` 之间的桥。

**状态管理模式**:
- `PackageListNotifier` 管理全局包裹列表，负责：
  - 从 Hive 加载与持久化
  - 合并同步数据（调用 `package_identity.dart` 判定同一包裹）
  - 生命周期推进（`pendingShipment → transit → delivering → arrived → pickedUp → archived`）
  - 清洗存量脏数据（外卖订单、OCR 幽灵数据、拼多多广告污染）
  - 到件通知触发（检测 `status` 变化并调用 `NotificationAdapter`）

## Critical Business Logic

### 1. Package Identity & Merging (P11-b)

**文件**: `lib/core/engine/package_identity.dart`

**核心规则**:
- **淘宝打码单号与菜鸟完整单号合并**: 淘宝物流详情页运单号打码（如 `YT12*******5678`），菜鸟驿站给完整单号。打码单号露出位数 ≥6 位、快递公司相同、非不同订单号时合并，ID 保留 `TB_<订单号>`。
- **旧 ID 迁移**: 旧版本存下的 `TB_<打码运单号>` 记录，同步时换成 `TB_<订单号>`，用户状态随记录迁移。
- **已取状态保护**: `pickedUpAt != null` 表示用户在 App 里手动点过「已取」，同步从不清空此字段（同步唯一会写它的是拒收态）。

**关键函数**:
```dart
bool maskedTrackingMatches(String masked, String full)  // 打码单号与完整单号是否对得上
int findUniqueMaskedMatch(List<Package> local, Package incoming)  // 查找唯一打码匹配
bool isLegacyMaskedTaobaoId(String id)  // 识别旧 TB_<打码运单号> ID
```

### 2. Taobao Sync Strategy

**文件**: `lib/platform/connectors/taobao_sync_rules.dart`

**策略**:
- **已签收订单跳过详情请求**: 本地已有、已签收（`pickedUp` 或 `archived`）、轨迹不为空 → 跳过 MTOP 物流详情请求（降低 API 调用量）
- **菜鸟优先级**: 淘宝详情判为已签收，但菜鸟驿站列表仍挂着这件（打码单号恰好匹配）且有取件码 → 改回待取件并带上菜鸟的取件码与完整单号（驿站代签 ≠ 用户取件）

### 3. Logistics Status Derivation

**文件**: `lib/core/engine/logistics_status_engine.dart`

基于时间排序的轨迹节点流推导 `PackageStatus`，区分主状态与异常 Overlay，输出物流稳定性等级与推荐同步间隔。

**状态优先级**（只能前进）:
```
pendingShipment → transit → delivering → arrived → pickedUp → archived
                                                              ↓
                                                          rejected (异常终结态)
```

### 4. Sync Speed Optimization (Phase 1-3)

**文件**: `lib/platform/connectors/concurrent_limiter.dart`, `sync_optimizer.dart`

**优化策略**:
- **并发拉取**: 三个平台订单详情并发拉取（最多 3 并发），100-400ms 随机延迟防风控
- **智能跳过**: 24 小时内已同步的订单跳过详情请求，已完成订单（已取件/已归档/已拒收）跳过
- **流式返回**: 每个包裹一产出就立即更新 UI，不等其他包裹

**性能提升**:
- 首次同步：14s → 5s（64% ↓）
- 二次同步（有已完成订单）：29s → 5s（83% ↓）
- 频繁刷新（5 分钟内）：14s → 秒返（95%+ ↓）

### 5. Background Sync & Keep-Alive

**文件**: 
- `lib/platform/sync/background_sync_service.dart`: 后台自动同步
- `lib/platform/keep_alive/keep_alive_service.dart`: 平台保活

**后台同步**:
- 自适应同步间隔（派送中 15 分钟、待取件 30 分钟、在途 1 小时、无活跃包裹暂停）
- 生命周期感知（前台暂停、后台启动、关闭停止）
- 到件通知利用 `PackageListNotifier._triggerArrivedNotification()`

**保活机制**:
- 调度决策在 `lib/core/engine/keep_alive_plan.dart`（纯 Dart、时间可注入、可单测）
- 间隔按 Cookie 年龄分档：0-3 天 24h、4-7 天 12h、8-10 天 6h、11+ 天 4h
- **`next_keep_alive_at` 已落盘**（box `keep_alive_state`），冷启动时闸门依然生效，不会重发心跳
- 用户同步后 6 小时内、或刚保活 2 小时内跳过；最近同步时间来自 `SyncHistoryManager`
- 心跳失败累计 3 次或明确判定失效 → 写 `setExpired` + 本地通知提醒（点击直达设置页）
- 拼多多心跳复用 `PddH5Connector` 的常驻 WebView（自建控制器会泄漏原生 WebView），只能前台运行
- 用户可关闭总开关或单平台开关，前后台路径都会尊重

### 6. Image URL Normalization (P11-b 后续)

**根因**: 淘宝商品图 URL 为协议相对格式 (`//img.alicdn.com/...`)，缺 `https:` 前缀，`Image.network` 加载失败。

**修复位置**:
- `taobao_connector.dart`: 源头补 `https:` 前缀
- `modern_package_card.dart` / `tracking_timeline_sheet.dart`: 渲染兜底，对历史 `//` 开头 URL 补 scheme

### 7. Notification Enhancement

**文件**: `lib/platform/notification/notification_adapter.dart`

**通知内容优化**:
- 标题：优先显示商品名（过长截断 18 字符），无商品名显示「快递到了」
- 内容：`快递公司 · 取件码:XXXX · 驿站名`（驿站名过长截断 12 字符）
- 无取件码时显示「已到 location」

## Testing

**测试文件结构**（节选，完整清单见 `test/`）:
```
test/
├── package_identity_test.dart          # 包裹身份判定、打码单号匹配
├── package_merge_sync_test.dart        # 同步合并逻辑（Hive + PackageListNotifier）
├── taobao_sync_rules_test.dart         # 淘宝同步策略
├── pickup_display_rules_test.dart      # Hero 取件码显示规则
├── timeline_view_test.dart             # 物流时间线视图
├── keep_alive_*_test.dart              # 保活调度、落盘、通知、历史
├── sync_optimizer_test.dart            # 智能跳过
├── legacy_regression_test.dart         # 回归测试
└── fixtures/                           # 测试输入样本（legacy 短信/通知 JSON、淘宝 SSR 详情文本）
```

> 测试全部为纯 Dart / Widget 测试，无需设备或网络；淘宝连接器测试直接喂 `test/fixtures/taobao/` 的 SSR 文本。

**运行特定测试**:
```bash
flutter test test/package_identity_test.dart
flutter test test/taobao_sync_rules_test.dart
```

**测试覆盖**: 271 个用例全部通过（无 skip）。新增/修改核心逻辑后跑 `flutter test` 确认全绿。

## Development Workflow

### When Adding/Modifying E-commerce Connectors

1. **解析逻辑放 `platform/connectors/`**: HTTP 调用、JSON 解析、Cookie 管理
2. **核心判定放 `core/`**: 状态推导、身份判定、合并规则（保持纯 Dart）
3. **更新 `package_identity.dart`**: 如涉及新的包裹 ID 格式或合并规则
4. **考虑并发优化**: 使用 `ThrottledExecutor` 并发拉取订单详情（参考现有实现）
5. **考虑智能跳过**: 使用 `SyncOptimizer.filterNeedsFetch()` 过滤已同步订单
6. **添加测试**: 在 `test/` 下覆盖新逻辑

### When Modifying Hive Models

1. 修改 `lib/platform/storage/hive_package.dart` 或 `hive_adapters.dart`
2. 运行代码生成:
   ```bash
   flutter pub run build_runner build --delete-conflicting-outputs
   ```
3. 更新 `PackageListNotifier` 的加载/持久化逻辑
4. 添加迁移逻辑（如需向后兼容）

### When Adding UI Components

1. **通用组件放 `lib/ui/components/`**
2. **屏幕级组件放对应 `screens/` 子目录**
3. **使用 Riverpod Providers 读取状态**: 避免直接操作 Hive

### When Optimizing Sync Performance

1. **并发拉取**: 使用 `ThrottledExecutor` 限制并发数（建议 3 并发）
2. **随机延迟**: 设置 `minDelay` 和 `maxDelay` 防止风控（淘宝/京东 100-300ms，拼多多 200-400ms）
3. **智能跳过**: 使用 `SyncOptimizer.filterNeedsFetch()` 过滤已同步订单
4. **流式返回**: 使用 `Stream<Package>` 逐个产出，不等全部完成
5. **验证测试**: 运行 `flutter test` 确保全部用例通过

## Common Pitfalls

1. **勿在 `core/` 导入 Flutter**: 破坏架构纯洁性，导致核心逻辑不可测
2. **勿在同步逻辑清空 `pickedUpAt`**: 用户手动标记的状态需保护（除非拒收）
3. **协议相对 URL 需补前缀**: 淘宝/拼多多图片 URL 可能缺 `https:`，渲染前补全
4. **打码单号需特殊处理**: 菜鸟驿站查询、身份判定时需识别 `*` 标记
5. **外卖订单需过滤**: 京东「达达」「秒送」等即时订单不是快递，需排除
6. **并发控制**: 使用 `ThrottledExecutor` 限制并发数，避免触发平台风控
7. **类型导入**: `CourierType` 和 `UrgencyLevel` 定义在 `core/models/package.dart`，不需要单独导入；`core/models/courier_type.dart` 是**未引用的历史遗留**，勿使用

## Project-Specific Conventions

- **交互语言**: 始终使用简体中文回复（与 `.cursor/rules/行为准则.mdc` 的 `Always respond in Chinese-simplified` 一致）
- **日志脱敏**: 运单号、订单号、取件码只记录平台前缀与计数，不打包完整值；提交前跑 `./tools/check_no_pii.sh`
- **中文注释**: 核心业务逻辑注释使用简体中文（领域语言为中文）
- **包裹 ID 格式**: `<平台前缀>_<平台订单号>` (如 `PDD_240101123456`, `TB_1000000000000000001`, `CN_YT1234567890123`)
- **Cookie 管理**: 各平台凭据存 `PlatformAuthStore`，WebView 捕获后持久化
- **并发限制**: 订单详情拉取最多 3 并发，随机延迟 100-400ms 防风控
- **静态检查**: `analysis_options.yaml` 基于 `flutter_lints`，额外强制 `prefer_const_constructors` / `prefer_const_declarations` / `avoid_print`。生产代码用 `debugPrint` / `DebugTrace`，勿新增 `print`（`main.dart` 中残留的 `print` 属历史遗留）
- **本地插件**: `plugins/secure_store`（path 依赖）封装 Android 安全存储，供凭据持久化使用

## Recent Optimizations (已完成)

最近完成的优化工作：

1. **同步速度优化 (Phase 1-3)**:
   - 并发拉取订单详情（3 并发）
   - 智能跳过已同步订单（24 小时内）
   - 流式返回数据
   - 性能提升：首次同步 64% ↓，二次同步 83% ↓

2. **后台自动同步**:
   - 自适应同步间隔（根据包裹状态动态调整）
   - 生命周期感知（前台暂停、后台启动）
   - 到件通知自动触发

3. **电商平台保活机制**:
   - 调度决策下沉 `lib/core/engine/keep_alive_plan.dart`，纯 Dart 可单测
   - 保活状态落盘（`keep_alive_state` box），修复每次冷启动重发心跳的风暴
   - 失效提醒闭环：本地通知 + 设置页入口，带去重与「发送成功才写标记」的兜底
   - 保活总开关 / 单平台开关 / 保活历史与成功率
   - 拼多多心跳改为复用 `PddH5Connector` 常驻 WebView，修复原生 WebView 泄漏

4. **通知内容优化**:
   - 显示商品名和取件码
   - 格式：`快递公司 · 取件码:XXXX · 驿站名`

详细文档见 `docs/` 目录：
- `docs/background-sync-implementation.md`: 后台同步实施总结
- `docs/keep-alive-implementation.md` / `docs/keep-alive-health-fix.md`: 保活机制与健康度修复
- `docs/sync-speed-implementation.md` / `-optimization.md` / `-phase2-implementation.md` / `-phase3-implementation.md`: 同步提速各阶段记录
- `docs/account-persistence.md`: 平台账号凭据持久化
- `docs/testing-guide.md`: 测试指南
