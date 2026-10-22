/// 京东快递（实物包裹）过滤器。
///
/// 只保留走传统物流的订单，其余（外卖/秒送/虚拟商品）一律过滤。
/// 判据是京东订单结构里的物流跟踪字段，而非商品文本：
/// 快递订单携带 progressInfo（progressId=logistics，指向 deal_wuliu 物流页），
/// 即时配送（specialDealList 含 isStore2Home）与虚拟商品没有该字段。
library;

/// 判断京东订单是否为快递包裹（有传统物流跟踪）。
bool isJdCourierDelivery(Map<String, dynamic> item) {
  final prog = item['progressInfo'] as Map<String, dynamic>?;
  return (prog?['progressId']?.toString() ?? '') == 'logistics';
}
