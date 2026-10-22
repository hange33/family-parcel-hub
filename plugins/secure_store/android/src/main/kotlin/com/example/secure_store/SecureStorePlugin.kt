package com.example.secure_store

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Android Keystore AES-GCM 凭据加密桥接。
 *
 * 以独立 FlutterPlugin 形式注册，而非注册在 MainActivity，使 WorkManager
 * 后台 isolate 的裸 FlutterEngine 也能通过 GeneratedPluginRegistrant 自动
 * 加载，从而在后台续期时读取加密存储的 Cookie。
 */
class SecureStorePlugin : FlutterPlugin {
    companion object {
        private const val CHANNEL = "com.example.pickup_app/secure_store"
        private const val KEY_ALIAS = "pickup_app_storage_key"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "encrypt" -> {
                    val value = call.argument<String>("value")
                    if (value == null) {
                        result.error("INVALID_ARGS", "value required", null)
                    } else {
                        result.success(encryptValue(value))
                    }
                }
                "decrypt" -> {
                    val value = call.argument<String>("value")
                    if (value == null) {
                        result.error("INVALID_ARGS", "value required", null)
                    } else {
                        result.success(decryptValue(value))
                    }
                }
                "isAvailable" -> result.success(getOrCreateSecretKey() != null)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    /** 获取（或首次创建）Android Keystore 中的 AES 主密钥；设备不支持时返回 null */
    private fun getOrCreateSecretKey(): javax.crypto.SecretKey? {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) return null
        return try {
            val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore")
            keyStore.load(null)
            val entry = keyStore.getEntry(KEY_ALIAS, null) as? java.security.KeyStore.SecretKeyEntry
            if (entry != null) return entry.secretKey

            val generator = javax.crypto.KeyGenerator.getInstance(
                android.security.keystore.KeyProperties.KEY_ALGORITHM_AES,
                "AndroidKeyStore"
            )
            generator.init(
                android.security.keystore.KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or
                        android.security.keystore.KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
            generator.generateKey()
        } catch (e: Throwable) {
            android.util.Log.w("SecureStore", "keystore key unavailable: $e")
            null
        }
    }

    /** AES-GCM 加密，输出 [ivLength(1B) | iv | ciphertext] 的 Base64；不可用时返回 null */
    private fun encryptValue(plain: String): String? {
        val key = getOrCreateSecretKey() ?: return null
        return try {
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, key)
            val iv = cipher.iv
            val cipherText = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            val buffer = java.nio.ByteBuffer.allocate(1 + iv.size + cipherText.size)
            buffer.put(iv.size.toByte())
            buffer.put(iv)
            buffer.put(cipherText)
            android.util.Base64.encodeToString(buffer.array(), android.util.Base64.NO_WRAP)
        } catch (e: Throwable) {
            android.util.Log.w("SecureStore", "encrypt failed: $e")
            null
        }
    }

    private fun decryptValue(encoded: String): String? {
        val key = getOrCreateSecretKey() ?: return null
        return try {
            val data = android.util.Base64.decode(encoded, android.util.Base64.NO_WRAP)
            val ivLength = data[0].toInt()
            if (ivLength <= 0 || data.size <= ivLength + 1) return null
            val iv = data.copyOfRange(1, 1 + ivLength)
            val cipherText = data.copyOfRange(1 + ivLength, data.size)
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                javax.crypto.Cipher.DECRYPT_MODE,
                key,
                javax.crypto.spec.GCMParameterSpec(128, iv)
            )
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        } catch (e: Throwable) {
            android.util.Log.w("SecureStore", "decrypt failed: $e")
            null
        }
    }
}
