import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import '../../main.dart';
import '../../core/debug/debug_trace.dart';
import '../../core/debug/metrics.dart';
import '../../core/engine/package_identity.dart';
import '../../core/engine/timeline_merge.dart';
import '../../platform/storage/hive_package.dart';
import '../../app/hero_decision.dart';
import '../../platform/notification/notification_adapter.dart';
import '../../platform/connectors/pdd_connector.dart';
import '../../platform/storage/platform_auth_store.dart';

class PackageListNotifier extends StateNotifier<List<Package>> {
  Box<HivePackage>? _box;

  /// 生命周期优先级：状态只能前进，不能倒退
  /// pendingShipment → transit → delivering → arrived → pickedUp → archived
  /// 已拒收为异常终结态，优先级最高（一旦拒收不允许被在途数据拉回）
  static const Map<PackageStatus, int> _statusPriority = {
    PackageStatus.pendingShipment: 0,
    PackageStatus.transit: 1,
    PackageStatus.delivering: 2,
    PackageStatus.arrived: 3,
    PackageStatus.pickedUp: 4,
    PackageStatus.archived: 5,
    PackageStatus.rejected: 6,
  };

  PackageListNotifier() : super([]) {
    debugPrint('[PackageListNotifier] initializing...');
    DebugTrace.separator('PACKAGE PROVIDER INIT');

    // ── Step 1: 获取 Hive box ────────────────────────────────
    try {
      _box = Hive.box<HivePackage>(kPackagesBox);
      debugPrint('[PackageListNotifier] Hive box opened: ${_box!.name}');
      debugPrint('[PackageListNotifier] box.isOpen: ${_box!.isOpen}');
      debugPrint('[PackageListNotifier] box.length: ${_box!.length}');
    } catch (e, stack) {
      DebugTrace.error('Hive box open FAILED', error: e, stackTrace: stack);
      debugPrint('[PackageListNotifier] Falling back to _initialPackages (no Hive persistence)');
      state = _initialPackages;
      return;
    }

    // ── Step 2: 从 Hive 加载 ─────────────────────────────────
    if (_box!.isNotEmpty) {
      final loaded = <Package>[];
      for (final hivePkg in _box!.values) {
        try {
          var pkg = hivePkg.toPackage();
          // 清理无意义的幽灵残留数据（如 description == 'OCR' 且无商品名、无取件码的无效卡片）
          if (pkg.description == 'OCR' && pkg.pickupCode.isEmpty && (pkg.goodsName == null || pkg.goodsName == 'OCR')) {
            debugPrint('[PackageListNotifier] Pruning phantom empty OCR package: ${packageIdForLog(pkg.id)}');
            continue;
          }
          // 清理存量误导入的餐饮外卖与秒送即时订单（非快递包裹）
          if (pkg.platform == 'jd' && _isFoodTakeoutPackage(pkg)) {
            debugPrint('[PackageListNotifier] Pruning takeout/food package: ${pkg.goodsName}');
            continue;
          }
          // 保护：已取件/已完成的包裹生命周期已完结，严禁被误判为在途
          if (pkg.status.isCompleted) {
            loaded.add(pkg);
            continue;
          }

          // 全面对齐拼多多官方分类体系进行存量状态自愈
          if (pkg.platform == 'pdd') {
            // 清洗历史被拼多多底部推荐流广告污染的描述（如“米哈游火花抱抱娃娃【200天内发货】”）
            if (pkg.description.contains('米哈游') ||
                pkg.description.contains('抱抱娃娃') ||
                pkg.description.contains('玩偶') ||
                pkg.description.contains('200天内发货')) {
              pkg = pkg.copyWith(description: '');
            }

            // 修复历史由于误抓取顶部 Tab 导致 description 被污染成导航栏的包裹
            if (pkg.description.contains('待付款') && pkg.description.contains('待收货')) {
              pkg = pkg.copyWith(description: '');
            }

            final officialStatus = PddStatusClassifier.resolve(
              statusPrompt: pkg.status.label,
              logisticsDesc: pkg.description,
              fullText: pkg.description,
              pickupCode: pkg.pickupCode,
            );

            // 若最新轨迹明确指明已派送至自提点/待取件，确保状态为待取件，且还原驿站名
            if ((officialStatus == PackageStatus.arrived || pkg.description.contains('已派送至')) &&
                pkg.status != PackageStatus.pickedUp) {
              var station = pkg.stationName;
              if (station == null || station.isEmpty || station == '未知驿站') {
                final m = RegExp(r'【([^】]{2,30})】').firstMatch(pkg.description);
                if (m != null) station = m.group(1);
              }
              pkg = pkg.copyWith(
                status: PackageStatus.arrived,
                stationName: station,
              );
            } else if (officialStatus == PackageStatus.delivering || officialStatus == PackageStatus.transit) {
            // 确实处于派送中或运输中的包裹：统一清空驿站名，并在残留串页取件码时一并清空
            final clearCode = isStaleTailPickupCode(pkg.pickupCode, pkg.trackingNumber);
            pkg = pkg.copyWith(
              pickupCode: clearCode ? '' : pkg.pickupCode,
              status: officialStatus,
              clearStationName: true,
            );
          } else if (officialStatus == PackageStatus.pendingShipment) {
              pkg = pkg.copyWith(status: PackageStatus.pendingShipment);
            }
          }
          loaded.add(pkg);
          debugPrint('[PackageListNotifier] loaded: id=${packageIdForLog(pkg.id)} status=${pkg.status.label}');
        } catch (e) {
          debugPrint('[PackageListNotifier] FAILED to convert HivePackage: $e');
        }
      }
      state = _consolidateLoaded(loaded);
      debugPrint('[PackageListNotifier] Loaded ${loaded.length} record(s) from Hive → ${state.length} package(s) after consolidation');
    } else {
      debugPrint('[PackageListNotifier] Hive box is EMPTY, using _initialPackages (${_initialPackages.length} items)');
      state = _initialPackages;
    }

    // ── Step 3: 同步回 Hive ──────────────────────────────────
    _sync();
    debugPrint('[PackageListNotifier] Synced ${state.length} packages back to Hive');
    DebugTrace.separator('PACKAGE PROVIDER INIT DONE');
    debugPrint('[PackageListNotifier] initialized. Total packages in state: ${state.length}');
  }

  void addPackage(Package package) {
    if (PlatformAuthStore().isBlacklisted(package.id, trackingNumber: package.trackingNumber)) {
      debugPrint('[PackageListNotifier] Package ${packageIdForLog(package.id)} is in deleted blacklist, skipping');
      return;
    }
    debugPrint('[PackageListNotifier] addPackage called (id: ${packageIdForLog(package.id)})');
    DebugTrace.separator('ADD PACKAGE START');
    debugPrint('[PackageListNotifier] incoming: courier=${package.courier.displayName} '
        'status=${package.status.label}');
    debugPrint('[PackageListNotifier] state before: ${state.length} packages');

    // ── Step 1: Dedupe ───────────────────────────────────────
    final existingIndex = _findExistingPackage(package);

    if (existingIndex != -1) {
      // ── Step 2a: Merge ─────────────────────────────────────
      DebugTrace.separator('MERGE EXISTING PACKAGE');
      final existing = state[existingIndex];
      debugPrint('[PackageListNotifier] existing package found! Merging (id: ${packageIdForLog(existing.id)})');
      debugPrint('[PackageListNotifier] existing: id=${packageIdForLog(existing.id)} '
          'status=${existing.status.label} '
          'notifiedArrived=${existing.notifiedArrived}');

      final resolvedStatus = _resolveStatus(
        existing.status,
        package.status,
        existingPickedUpAt: existing.pickedUpAt,
        existingPickupCode: existing.pickupCode,
        existingStationName: existing.stationName,
      );

      // 电商平台信息更丰富时（如 PDD、JD、淘宝已有具体商品名和图文），保留已有商品图文，不被菜鸟/快递的通用描述覆盖
      final samePlatform = existing.platform == package.platform;
      final hasSpecificGoodsName = existing.goodsName != null &&
          existing.goodsName!.isNotEmpty &&
          !_looksLikeLogisticsText(existing.goodsName!) &&
          existing.goodsName != '快件包裹' &&
          existing.goodsName != '快递包裹' &&
          existing.goodsName != 'OCR';
      final hasSpecificPlatform = existing.platform != null &&
          existing.platform!.isNotEmpty &&
          existing.platform != 'other' &&
          existing.platform != 'cainiao';

      final updatedGoodsName = samePlatform
          ? ((package.goodsName?.isNotEmpty == true && !_looksLikeLogisticsText(package.goodsName!))
              ? package.goodsName
              : existing.goodsName)
          : (hasSpecificGoodsName ? existing.goodsName : (package.goodsName ?? existing.goodsName));

      final updated = existing.copyWith(
        // 旧的 TB_<打码运单号> / CN_<运单号> 换成 TB_<订单号>；用户状态（已取、归档、pickedUpAt）随 existing 带过去，
        // _sync 会删掉 Hive 里的旧 key
        id: resolveMergedPackageId(existing, package),
        // 承运商与运单号：新数据更权威时（非默认值）覆盖
        courier: package.courier != CourierType.other ? package.courier : existing.courier,
        trackingNumber: keepFullTrackingNumber(
            existing.trackingNumber,
            package.trackingNumber.isNotEmpty && package.trackingNumber != package.id.replaceFirst('PDD_', '')
                ? package.trackingNumber
                : existing.trackingNumber),
        goodsName: updatedGoodsName,
        goodsImageUrl: existing.goodsImageUrl ?? package.goodsImageUrl,
        platform: hasSpecificPlatform ? existing.platform : (package.platform ?? existing.platform),
        stationName: () {
          // 运输中/派送中/待发货阶段包裹尚未到达自提点，一律不保留驿站名（避免把“转运中心”误当驿站）
          if (resolvedStatus == PackageStatus.delivering ||
              resolvedStatus == PackageStatus.transit ||
              resolvedStatus == PackageStatus.pendingShipment) {
            return null;
          }
          return preferStationName(existing.stationName ?? '', package.stationName ?? '');
        }(),
        clearStationName: resolvedStatus == PackageStatus.delivering ||
            resolvedStatus == PackageStatus.transit ||
            resolvedStatus == PackageStatus.pendingShipment,
        location: package.location.isNotEmpty ? package.location : existing.location,
        originalStation: package.originalStation.isNotEmpty ? package.originalStation : existing.originalStation,
        pickupCode: () {
          final incomingScore = _pickupCodeScore(package.pickupCode);
          final currentScore = _pickupCodeScore(existing.pickupCode);

          // 新数据是可信取件码且不弱于旧值 → 采用
          if (incomingScore > 0 && incomingScore >= currentScore) return package.pickupCode;

          // 旧值可信 → 保留（防止隐私号/掩码手机号覆盖真实取件码）
          if (currentScore > 0) return existing.pickupCode;

          // 双方都不可信：处于在途阶段则彻底清空历史残留
          if (resolvedStatus == PackageStatus.delivering ||
              resolvedStatus == PackageStatus.transit ||
              resolvedStatus == PackageStatus.pendingShipment) {
            return '';
          }
          return existing.pickupCode;
        }(),
        description: package.description.isNotEmpty ? package.description : existing.description,
        urgency: _higherUrgency(existing.urgency, package.urgency),
        addedAt: package.addedAt.isAfter(existing.addedAt) ? package.addedAt : existing.addedAt,
        status: resolvedStatus,
        // 同步从不清 pickedUpAt（它标记用户手动点过已取）；首次进入拒收态时记录结束时间，供已完成列表排序
        pickedUpAt: existing.pickedUpAt ?? (resolvedStatus == PackageStatus.rejected ? DateTime.now() : null),
        transitFingerprint: package.transitFingerprint ?? existing.transitFingerprint,
        // 时间轴取并集：避免某次详情页加载不全时把完整轨迹覆盖成残缺版本
        rawTimelineJson: _mergeTimelineJson(existing.rawTimelineJson, package.rawTimelineJson),
      );

      debugPrint('[PackageListNotifier] merged: status=${updated.status.label} '
          'urgency=${updated.urgency.label}');

      state = [
        for (int i = 0; i < state.length; i++)
          if (i == existingIndex) updated else state[i],
      ];

      if (updated.status.isArrived && !updated.notifiedArrived) {
        debugPrint('[PackageListNotifier] arrived, triggering notification');
        _triggerArrivedNotification(updated);
      }

      // 同步发现包裹已签收/已拒收：撤销可能仍在等待的到件与 24 小时提醒
      final becameTerminal = (updated.status == PackageStatus.pickedUp &&
              existing.status != PackageStatus.pickedUp) ||
          (updated.status == PackageStatus.rejected &&
              existing.status != PackageStatus.rejected);
      if (becameTerminal) {
        debugPrint('[PackageListNotifier] terminal status by sync (${updated.status.label}), cancelling notifications');
        NotificationAdapter().cancelNotification(updated.id).catchError((_) {});
      }
    } else {
      // ── Step 2b: Create ────────────────────────────────────
      DebugTrace.separator('CREATE NEW PACKAGE');
      debugPrint('[PackageListNotifier] no existing package found, creating new');
      debugPrint('[PackageListNotifier] new: id=${packageIdForLog(package.id)}');

      state = [...state, package];

      if (package.status.isArrived && !package.notifiedArrived) {
        debugPrint('[PackageListNotifier] arrived, triggering notification');
        _triggerArrivedNotification(package);
      }
    }

    // ── Step 3: Persist ──────────────────────────────────────
    _sync();
    debugPrint('[PackageListNotifier] addPackage completed. Final state: ${state.length} packages');

    DebugTrace.separator('ADD PACKAGE COMPLETE');
  }
  
  /// 触发到件通知
  void _triggerArrivedNotification(Package package) {
    final notificationService = NotificationAdapter();
    
    // 标记为已通知
    final updatedPackage = package.copyWith(notifiedArrived: true);
    state = [
      for (final p in state)
        if (p.id == package.id) updatedPackage else p,
    ];
    _sync();
    
    // 异步发送通知（在无通知插件的环境，例如单元测试中，静默跳过）
    notificationService.showArrivedNotification(package).catchError((_) {});
    notificationService.scheduleReminderNotification(package).catchError((_) {});
  }
  
  /// 查找已存在的相同包裹
  ///
  /// 判定为同一包裹的依据（按可靠性排序）：
  /// 1) 包裹 ID（平台订单号派生的稳定标识）
  /// 2) 运单号（快递单号全球唯一）
  /// 3) 取件码 + 平台一致
  ///
  /// 注意：同一包裹在不同平台会拿到不同形态的凭据（例如拼多多的「后5位 98898」
  /// 与菜鸟驿站的货架码「16-1-7002」），因此**不能**用「取件码不同」来判定为不同包裹。
  int _findExistingPackage(Package package) {
    final incomingCode = package.pickupCode.trim();
    final incomingTracking = package.trackingNumber.trim();

    // 1) 包裹 ID 精确匹配（平台订单号派生的稳定标识，最可靠）
    final idIdx = state.indexWhere((p) => p.id == package.id);
    if (idIdx != -1) {
      Metrics.inc('dedupe.hit');
      debugPrint('[PackageListNotifier] → HIT: index=$idIdx (id match)');
      return idIdx;
    }

    // 2) 运单号精确匹配（同一运单号必然是同一包裹）
    if (incomingTracking.isNotEmpty) {
      // 打码单号相同不代表同一包裹：两个不同的淘宝订单不合并
      final idx = state.indexWhere((p) =>
          p.trackingNumber.trim() == incomingTracking &&
          !(isMaskedTrackingNumber(incomingTracking) && isDistinctTaobaoOrder(p, package)));
      if (idx != -1) {
        Metrics.inc('dedupe.hit');
        debugPrint('[PackageListNotifier] → HIT: index=$idx (tracking match)');
        return idx;
      }
    }

    // 2b) 打码单号 ↔ 完整单号（淘宝详情页打码、菜鸟完整）：同快递公司、露出位数达标、恰好命中一个
    final maskedIdx = findUniqueMaskedMatch(state, package);
    if (maskedIdx != -1) {
      Metrics.inc('dedupe.hit');
      debugPrint('[PackageListNotifier] → HIT: index=$maskedIdx (masked tracking match)');
      return maskedIdx;
    }

    // 3) 取件码 + 平台一致（仅当取件码非空时才作为身份）
    if (incomingCode.isNotEmpty) {
      final idx = state.indexWhere((p) =>
          p.pickupCode.trim().isNotEmpty &&
          p.pickupCode.trim() == incomingCode &&
          (p.platform ?? '') == (package.platform ?? ''));
      if (idx != -1) {
        Metrics.inc('dedupe.hit');
        debugPrint('[PackageListNotifier] → HIT: index=$idx (pickupCode match)');
        return idx;
      }
    }

    Metrics.inc('dedupe.miss');
    debugPrint('[PackageListNotifier] → NO MATCH');
    return -1;
  }
  
  UrgencyLevel _higherUrgency(UrgencyLevel a, UrgencyLevel b) {
    return a.score >= b.score ? a : b;
  }

  /// 「后N位 XXXXX」形态的取件码必须与本单运单号尾部一致。
  ///
  /// 不一致说明该码来自页面上其它包裹（串单残留），属于脏数据；
  /// 运单号缺失或仅为订单编号（含「-」）时无从校验，保留原码。
  @visibleForTesting
  static bool isStaleTailPickupCode(String pickupCode, String trackingNumber) {
    final tail = RegExp(r'^后[四五五六\d]+位\s*([0-9A-Za-z]{3,8})$').firstMatch(pickupCode.trim());
    if (tail == null) return false;
    final tn = trackingNumber.trim();
    if (tn.isEmpty || tn.contains('-')) return false;
    return !tn.endsWith(tail.group(1)!);
  }

  /// 取件码可信度评分：越高越可信，0 表示不是取件码
  ///
  /// 用于避免快递平台的隐私号 / 掩码手机号（如 138****0000）覆盖真实的驿站取件码，
  /// 同时保证同一包裹在不同平台拿到不同形态凭据时，选出更直接可用的那个（货架码 > 单号后N位）。
  int _pickupCodeScore(String code) {
    final c = code.trim();
    if (c.isEmpty) return 0;
    // 含掩码的隐私号/手机号，绝不是取件码
    if (c.contains('*')) return 0;
    // 纯 11 位手机号
    if (RegExp(r'^1[3-9]\d{9}$').hasMatch(c)) return 0;
    // 货架码（驿站分配的物理位置码，如 16-1-7002）最直接可用
    if (RegExp(r'^\d{1,3}-\d{1,3}-\d{2,5}$').hasMatch(c)) return 5;
    // 「后N位 XXXXX」这类显式取件凭证
    if (RegExp(r'^后[四五五六\d]+位\s*[0-9A-Za-z]{3,8}$').hasMatch(c)) return 4;
    // 普通短码
    if (RegExp(r'^[0-9A-Za-z\-]{3,12}$').hasMatch(c)) return 2;
    return 1;
  }

  /// 驿站名择优：泛称不得覆盖具体网点名。
  ///
  /// 菜鸟接口拿不到驿站全称时会回落到泛称「菜鸟驿站」，但多数具体网点名本身就含这三个字
  /// （如「邢台信都区绿城诚园北门店菜鸟驿站」），所以无法用「是否含菜鸟驿站」判断具体性，
  /// 只能按「是否恰好等于某个泛称」来判定，否则具体名会被泛称覆盖掉。
  @visibleForTesting
  static String preferStationName(String current, String incoming) {
    final cur = current.trim();
    final inc = incoming.trim();
    if (inc.isEmpty || inc == '未知驿站') return cur;
    if (cur.isEmpty || cur == '未知驿站') return inc;

    // 泛称的信息量排序，用于「两个泛称之间取更具体的那个」
    const genericRank = {'菜鸟驿站': 3, '驿站': 2, '自提点': 1};
    final curRank = genericRank[cur];
    final incRank = genericRank[inc];

    if (curRank != null && incRank != null) return incRank >= curRank ? inc : cur;
    // 已有具体网点名，新流入只是泛称：保留具体名；具体名没带「菜鸟驿站」字样时补上前缀
    if (curRank == null && incRank != null) {
      return inc == '菜鸟驿站' && !cur.contains('菜鸟驿站') ? '菜鸟驿站 · $cur' : cur;
    }
    // 新流入更具体 → 采用
    return inc;
  }

  /// 是否为具体的商品名（排除各家连接器生成的通用占位名）
  bool _isSpecificGoodsName(String? name) {
    if (name == null || name.isEmpty) return false;
    // 误把物流/取件说明当成商品名的脏数据不算「具体商品名」，
    // 这样它在合并时会被真实商品名或中性占位名替换掉
    if (_looksLikeLogisticsText(name)) return false;
    return name != '快件包裹' && name != '快递包裹' && name != '拼多多包裹' && name != 'OCR';
  }

  /// 判断一个「商品名」是否其实是取件/物流说明文本（属于解析脏数据）
  bool _looksLikeLogisticsText(String name) {
    const keywords = ['取件', '出示', '提货', '取货码', '快递单号', '取件码'];
    return keywords.any(name.contains);
  }

  /// 是否为具体来源平台（排除通用/聚合来源）
  bool _isSpecificPlatform(String? platform) {
    if (platform == null || platform.isEmpty) return false;
    return platform != 'other' && platform != 'cainiao';
  }

  /// 载入时合并重复卡片：同一运单号只保留一张
  List<Package> _consolidateLoaded(List<Package> loaded) {
    final result = <Package>[];
    final indexByTracking = <String, int>{};
    var mergedCount = 0;

    for (final p in loaded) {
      final tn = p.trackingNumber.trim();
      if (tn.isEmpty) {
        result.add(p);
        continue;
      }
      final idx = indexByTracking[tn];
      if (idx == null) {
        indexByTracking[tn] = result.length;
        result.add(p);
      } else if (isMaskedTrackingNumber(tn) && isDistinctTaobaoOrder(result[idx], p)) {
        result.add(p); // 打码单号相同的两个淘宝订单是两个包裹
      } else {
        result[idx] = _mergeDuplicatePair(result[idx], p);
        mergedCount++;
      }
    }

    if (mergedCount > 0) {
      debugPrint('[PackageListNotifier] Consolidated $mergedCount duplicate package(s) by tracking number');
    }
    return result;
  }

  /// 合并同一运单号的两条记录：状态取更靠后的、取件码取更可信的、商品信息取更具体的
  Package _mergeDuplicatePair(Package a, Package b) {
    final aPri = _statusPriority[a.status] ?? 0;
    final bPri = _statusPriority[b.status] ?? 0;
    final primary = bPri > aPri ? b : a;
    final secondary = bPri > aPri ? a : b;

    final primaryCodeScore = _pickupCodeScore(primary.pickupCode);
    final secondaryCodeScore = _pickupCodeScore(secondary.pickupCode);

    return primary.copyWith(
      courier: primary.courier != CourierType.other ? primary.courier : secondary.courier,
      goodsName: _isSpecificGoodsName(primary.goodsName)
          ? primary.goodsName
          : (_isSpecificGoodsName(secondary.goodsName) ? secondary.goodsName : primary.goodsName),
      goodsImageUrl: primary.goodsImageUrl ?? secondary.goodsImageUrl,
      platform: _isSpecificPlatform(primary.platform)
          ? primary.platform
          : (_isSpecificPlatform(secondary.platform) ? secondary.platform : primary.platform),
      pickupCode: primaryCodeScore >= secondaryCodeScore ? primary.pickupCode : secondary.pickupCode,
      stationName: (primary.stationName?.trim().isNotEmpty == true) ? primary.stationName : secondary.stationName,
      description: primary.description.isNotEmpty ? primary.description : secondary.description,
      // 时间轴取并集：重复记录合并时同样不允许节点丢失
      rawTimelineJson: _mergeTimelineJson(primary.rawTimelineJson, secondary.rawTimelineJson),
      location: primary.location.isNotEmpty ? primary.location : secondary.location,
      // 任一条已发过到件通知即视为已通知，避免合并后重复推送
      notifiedArrived: primary.notifiedArrived || secondary.notifiedArrived,
      // 保留任一条上的取件确认时间，避免合并后丢失手动确认痕迹
      pickedUpAt: primary.pickedUpAt ?? secondary.pickedUpAt,
    );
  }

  /// 状态只能前进，不能倒退（支持未手动取件时的异常逆向智能自愈校准）
  ///
  /// lifecycle: pendingShipment(0) → transit(1) → delivering(2) → arrived(3) → pickedUp(4) → archived(5)
  PackageStatus _resolveStatus(
    PackageStatus existing,
    PackageStatus incoming, {
    DateTime? existingPickedUpAt,
    String existingPickupCode = '',
    String? existingStationName,
  }) {
    // 智能校准1：若历史数据因无待发货状态被误判为 transit（在途），
    // 重新抓取明确为待发货时，允许自动校正回待发货
    if (existing == PackageStatus.transit && incoming == PackageStatus.pendingShipment) {
      debugPrint('[PackageListNotifier] Calibrating transit -> pendingShipment (corrected false transit)');
      return PackageStatus.pendingShipment;
    }

    // 智能校准2：若历史记录曾被同步误判为 pickedUp（但用户未手动确认取件 existingPickedUpAt == null），
    // 且平台最新同步明确识别为派送中、待取件或在途，允许自愈校正回真实活跃状态
    if (existing == PackageStatus.pickedUp &&
        existingPickedUpAt == null &&
        (incoming == PackageStatus.delivering ||
         incoming == PackageStatus.arrived ||
         incoming == PackageStatus.transit)) {
      debugPrint('[PackageListNotifier] Self-healing falsely pickedUp package back to ${incoming.label}');
      return incoming;
    }

    // 保护已到达状态：包裹若确有到站证据（真实取件码或有效驿站名），
    // 列表接口简略的在途中数据严禁将其倒退降级；
    // 若既无取件码也无驿站名，则说明该 arrived 可能来自脏数据，允许按真实状态校正。
    if (existing == PackageStatus.arrived &&
        (incoming == PackageStatus.delivering || incoming == PackageStatus.transit)) {
      final hasArrivalEvidence = _pickupCodeScore(existingPickupCode) > 0 ||
          (existingStationName?.trim().isNotEmpty ?? false);
      if (hasArrivalEvidence) {
        debugPrint('[PackageListNotifier] Protecting arrived package from being downgraded to ${incoming.label}');
        return PackageStatus.arrived;
      }
      debugPrint('[PackageListNotifier] arrived without evidence, allowing correction to ${incoming.label}');
    }

    final existingPri = _statusPriority[existing] ?? 0;
    final incomingPri = _statusPriority[incoming] ?? 0;

    DebugTrace.separator('STATUS RESOLUTION');
    debugPrint('[PackageListNotifier] existing=${existing.label}($existingPri) '
        'incoming=${incoming.label}($incomingPri)');

    final resolved = incomingPri > existingPri ? incoming : existing;
    debugPrint('[PackageListNotifier] resolved=${resolved.label}');

    return resolved;
  }

  void markPickedUp(String id) {
    // 取消该包裹的通知
    NotificationAdapter().cancelNotification(id);
    
    state = [
      for (final p in state)
        if (p.id == id)
          p.copyWith(
            status: PackageStatus.pickedUp,
            pickedUpAt: DateTime.now(),
          )
        else
          p,
    ];
    _sync();
  }

  /// 清空所有包裹数据
  void clearAll() {
    state = [];
    _sync();
  }

  /// 删除单个包裹
  void removePackage(String id) {
    final existingIndex = state.indexWhere((p) => p.id == id);
    if (existingIndex != -1) {
      final existing = state[existingIndex];
      PlatformAuthStore().addToBlacklist(existing.id, trackingNumber: existing.trackingNumber);
    } else {
      PlatformAuthStore().addToBlacklist(id);
    }
    NotificationAdapter().cancelNotification(id);
    state = state.where((p) => p.id != id).toList();
    _sync();
  }
  
  /// 自动归档已取件超过7天的包裹
  void autoArchive() {
    state = [
      for (final p in state)
        p.shouldAutoArchive 
            ? p.copyWith(
                status: PackageStatus.archived,
                archivedAt: DateTime.now(),
              )
            : p,
    ];
    _sync();
  }

  /// 清除所有已完成（已取件 + 已归档）的包裹
  void clearCompleted() {
    state = state.where((p) => !p.status.isCompleted).toList();
    _sync();
  }

  void _sync() {
    final box = _box;
    if (box == null) return;

    // Write-through: put all current packages
    final stateIds = <String>{};
    for (final p in state) {
      stateIds.add(p.id);
      box.put(p.id, HivePackage.fromPackage(p));
    }

    // Remove packages no longer in state
    for (final key in box.keys.toList()) {
      if (!stateIds.contains(key)) {
        box.delete(key);
      }
    }
  }
}

final packageListProvider =
    StateNotifierProvider<PackageListNotifier, List<Package>>((ref) {
  return PackageListNotifier();
});

final pendingPackagesProvider = Provider<List<Package>>((ref) {
  final pending = ref
      .watch(packageListProvider)
      .where((p) => p.status.isPending)
      .toList();
  
  pending.sort((a, b) {
    // 1. 待取件（已到达或已有取件码）最高置顶优先级
    final isPickupA = a.status == PackageStatus.arrived || a.pickupCode.trim().isNotEmpty;
    final isPickupB = b.status == PackageStatus.arrived || b.pickupCode.trim().isNotEmpty;
    if (isPickupA != isPickupB) {
      return isPickupA ? -1 : 1;
    }

    // 2. 派送中状态次之
    final isDeliveringA = a.status == PackageStatus.delivering;
    final isDeliveringB = b.status == PackageStatus.delivering;
    if (isDeliveringA != isDeliveringB) {
      return isDeliveringA ? -1 : 1;
    }

    // 3. 运送中状态排在待发货之前
    final isTransitA = a.status == PackageStatus.transit;
    final isTransitB = b.status == PackageStatus.transit;
    if (isTransitA != isTransitB) {
      return isTransitA ? -1 : 1;
    }

    // 4. 同等状态下，按综合紧急程度分数降序
    final urgencyCompare = b.compositeUrgencyScore.compareTo(a.compositeUrgencyScore);
    if (urgencyCompare != 0) return urgencyCompare;

    // 4. 最新到达或更新的时间从新到旧排序
    return b.addedAt.compareTo(a.addedAt);
  });
  
  return pending;
});

final completedPackagesProvider = Provider<List<Package>>((ref) {
  final completed =
      ref.watch(packageListProvider).where((p) => p.status.isCompleted).toList();
  // 已完成列表按「结束时间」倒序排列：最近取件/拒收的排在最前，便于回看
  completed.sort((a, b) => _completedAt(b).compareTo(_completedAt(a)));
  return completed;
});

/// 包裹进入终结状态的时间（取件、归档或拒收），用于已完成列表排序
DateTime _completedAt(Package p) => p.pickedUpAt ?? p.archivedAt ?? p.addedAt;

final groupedPendingPackagesProvider = Provider<Map<String, List<Package>>>((ref) {
  final pending = ref.watch(pendingPackagesProvider);
  final grouped = <String, List<Package>>{};
  
  for (final package in pending) {
    final location = package.displayLocation;
    grouped.putIfAbsent(location, () => []).add(package);
  }
  
  return grouped;
});

final heroDecisionProvider = Provider<HeroDecision>((ref) {
  final packages = ref.watch(packageListProvider);
  return HeroDecisionService.decide(packages);
});

const _initialPackages = <Package>[];

/// 合并两份物流时间轴 JSON：取节点并集（按「时间 + 描述」去重，时间倒序排列）。
String? _mergeTimelineJson(String? existingJson, String? incomingJson) {
  return mergeTimelineJson(existingJson, incomingJson);
}

bool _isFoodTakeoutPackage(Package pkg) {
  const foodKeywords = [
    '外卖', '秒送', '达达', '骑手', '汉堡', '堡', '螺蛳粉', '冒菜', '米线',
    '奶茶', '咖啡', '快餐', '餐饮', '堂食', '烧烤', '炸鸡', '烤鸭', '麻辣烫',
    '人份', '套餐', '柠檬水', '饮品', '捞饭', '炒饭', '米饭', '鸡丁', '炸蛋', '小菜'
  ];
  final text = '${pkg.goodsName ?? ""} ${pkg.location} ${pkg.stationName ?? ""} ${pkg.description}';
  return foodKeywords.any(text.contains);
}
