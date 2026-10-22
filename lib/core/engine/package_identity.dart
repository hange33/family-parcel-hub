/// 包裹身份与合并规则 - 纯 Dart（不引用 Flutter）
///
/// P11-b 后续（技术负责人、测试 10-07 定）：
/// - 淘宝物流详情页给的运单号是打码的（如 `YT12*******5678`），菜鸟给的是完整单号。
///   两边对上时合并成一张卡，ID 保留 `TB_<订单号>`。
/// - 旧版本存下的 `TB_<打码运单号>` 记录，同步时换成 `TB_<订单号>`，用户状态随记录带过去。
/// - `pickedUpAt != null` 表示用户在 App 里手动点过「已取」；同步从不清它（同步唯一会写它的是拒收态）。
library;

import '../models/package.dart';
import '../models/package_status.dart';

/// 打码单号露出的字符（前几位 + 后几位）合计至少这么多位才允许合并
const int kMinVisibleTrackingChars = 6;

/// 单号是否打码（含 `*`）
bool isMaskedTrackingNumber(String trackingNumber) => trackingNumber.contains('*');

/// 打码单号露出的字符数（非 `*` 的字符）
int visibleTrackingChars(String masked) => masked.trim().replaceAll('*', '').length;

/// 打码单号 [masked] 与完整单号 [full] 是否对得上：
/// 长度相同；完整单号不含 `*`；打码单号每一位露出的字符都与完整单号同位置字符相同（不区分大小写），
/// 即露出的前几位、后几位都对得上；露出合计至少 [kMinVisibleTrackingChars] 位。
bool maskedTrackingMatches(String masked, String full) {
  final m = masked.trim();
  final f = full.trim();
  if (!isMaskedTrackingNumber(m) || f.isEmpty || isMaskedTrackingNumber(f)) return false;
  if (m.length != f.length) return false;
  if (visibleTrackingChars(m) < kMinVisibleTrackingChars) return false;
  for (var i = 0; i < m.length; i++) {
    final c = m[i];
    if (c == '*') continue;
    if (c.toUpperCase() != f[i].toUpperCase()) return false;
  }
  return true;
}

/// 快递公司相同且已知（任一方认不出公司时不算相同，不合并）
bool sameKnownCourier(Package a, Package b) {
  final ca = a.effectiveCourier;
  return ca != CourierType.other && ca == b.effectiveCourier;
}

/// 在 [local] 里找与 [incoming] 打码/完整单号对得上的包裹：一方打码、一方完整，
/// 快递公司相同，露出位数达标。恰好命中一个返回下标；没有或命中多个返回 -1（不合并）。
int findUniqueMaskedMatch(List<Package> local, Package incoming) {
  final tn = incoming.trackingNumber.trim();
  if (tn.isEmpty) return -1;
  final incomingMasked = isMaskedTrackingNumber(tn);
  var hit = -1;
  for (var i = 0; i < local.length; i++) {
    final p = local[i];
    final ptn = p.trackingNumber.trim();
    if (ptn.isEmpty || isMaskedTrackingNumber(ptn) == incomingMasked) continue;
    final ok = incomingMasked ? maskedTrackingMatches(tn, ptn) : maskedTrackingMatches(ptn, tn);
    if (!ok || !sameKnownCourier(p, incoming) || isDistinctTaobaoOrder(p, incoming)) continue;
    if (hit != -1) return -1; // 命中多个：不合并
    hit = i;
  }
  return hit;
}

/// 旧版本存下的 `TB_<打码运单号>` 记录
bool isLegacyMaskedTaobaoId(String id) {
  if (!id.startsWith('TB_')) return false;
  final rest = id.substring(3);
  // 拆单后的 TB_<订单号>_<运单号> 不算旧 ID
  return rest.contains('*') && !rest.contains('_');
}

/// 两条都是新式 `TB_<订单号>` 且订单号不同：一定是两个包裹，打码单号再像也不合并
bool isDistinctTaobaoOrder(Package a, Package b) =>
    a.id != b.id &&
    a.id.startsWith('TB_') &&
    b.id.startsWith('TB_') &&
    !isLegacyMaskedTaobaoId(a.id) &&
    !isLegacyMaskedTaobaoId(b.id);

/// 合并后用哪个 ID：新来的是 `TB_<订单号>`，而本地是旧的 `TB_<打码运单号>` 或 `CN_<运单号>` 时换成新 ID；
/// 其余保留本地 ID。
String resolveMergedPackageId(Package existing, Package incoming) {
  final inc = incoming.id;
  if (existing.id == inc) return existing.id;
  if (!inc.startsWith('TB_') || isLegacyMaskedTaobaoId(inc)) return existing.id;
  if (isLegacyMaskedTaobaoId(existing.id) || existing.id.startsWith('CN_')) return inc;
  return existing.id;
}

/// 合并时单号不降级：本地已是完整单号、新来的是打码单号时保留本地的
String keepFullTrackingNumber(String existing, String candidate) {
  if (isMaskedTrackingNumber(candidate) && existing.trim().isNotEmpty && !isMaskedTrackingNumber(existing)) {
    return existing;
  }
  return candidate;
}

/// 用户在 App 里手动处理过（点过「已取」或已归档），菜鸟/平台同步不能把它改回待取件。
///
/// 平台签收和用户点已取都是 pickedUp，区别只在 pickedUpAt：只有用户手动操作会写它，
/// 撤销（restorePackage）会清掉它。自动归档的前提也是 pickedUpAt 不为空。
bool isUserHandledPickup(Package p) =>
    p.status == PackageStatus.archived || (p.status == PackageStatus.pickedUp && p.pickedUpAt != null);

/// 日志里代替包裹 ID：只留平台前缀（如 `TB_…`、`CN_…`），ID 里含订单号 / 运单号，不能打进日志
String packageIdForLog(String id) {
  final i = id.indexOf('_');
  return i <= 0 ? '…' : '${id.substring(0, i + 1)}…';
}
