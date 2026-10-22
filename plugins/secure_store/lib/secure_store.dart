/// Android Keystore AES-GCM 凭据加密桥接（Dart 侧）。
///
/// 与 [MethodChannel] 的 channel 名保持一致；历史代码直接使用
/// `MethodChannel('com.example.pickup_app/secure_store')` 亦可。
library;

import 'package:flutter/services.dart';

const MethodChannel secureStoreChannel =
    MethodChannel('com.example.pickup_app/secure_store');
