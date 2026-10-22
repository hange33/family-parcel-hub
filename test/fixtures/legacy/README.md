# test/fixtures/legacy：旧测试集样本（已脱敏）

- **来源**：旧仓库 pickup_app 的 `test/fixtures/{good,edge,bad,notifications}/*.txt`。原始文件里有真实取件码等信息，只放在仓库外的私有目录，**不进 git**。
- **生成方式**：每个文件都是 P11-a 脱敏器 `DiagSanitizer.sanitizeRaw(原文)` 的**原样输出**，未做任何手工修改。脱敏器来自 PR #3（`origin/feat/p11a-taobao-capture` @ `fd41655`），这里只把它当工具用，代码上不依赖 #3。格式为 `{"_unparsed": true, "raw": "<脱敏后文本>"}`。
- **脱敏效果**：取件码保留格式，数字全部换成 9（`9-9-9999`），所以测试期望值也是脱敏后的值。
- **入库标准**：脱敏后人工检查，**只要还残留以下任一类信息就不入库**：带楼栋或门牌的地址、未打码的取件码、运单号、订单号、人名、部分打码的手机号、真实小区或城区名。
- **对应测试**：`test/legacy_regression_test.dart`。

| 目录 | 文件 | 断言 |
|---|---|---|
| bad | dashboard_homepage, settings_page, shopping_product | `TextSanitizer.shouldAbortParse` 为 true |
| edge | conflict_transit_arrival, mixed_courier_names, very_short_sms | 解析不抛异常 |
| good | sf_arrived_with_code, arrived_with_code_override | 能创建包裹；有取件码时状态为待取件 |
| notifications | pdd_arrived, multi_package_notification, non_courier_notification | 取件码、状态、驿站；多包裹；非快递通知 |

`non_courier_notification` 里的「张三」是常见占位名，不是真实人名。`sf_arrived_with_code` 里的驿站名没有城市或区县信息。
