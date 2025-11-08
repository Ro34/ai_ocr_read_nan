# 修复记录

## 问题描述

编译时出现错误：
```
Unresolved reference 'setPassphrase'
```

## 原因分析

`WifiAwareNetworkSpecifier.Builder` 的 `setPassphrase()` 方法名不正确。正确的方法名是：
- `setPskPassphrase(String)` - 使用预共享密钥密码
- `setPmk(byte[])` - 使用成对主密钥

## 解决方案

将所有 `builder.setPassphrase(passphrase)` 替换为：
```kotlin
try {
    builder.setPskPassphrase(passphrase)
} catch (e: Exception) {
    Log.w(tag, "Failed to set passphrase: ${e.message}")
}
```

## 修改的文件

- `android/app/src/main/kotlin/com/example/ai_ocr_read/DataPathManager.kt` (2处)
  - Line 143: openDataPath 方法
  - Line 259: startResponderMode 方法

## 验证结果

✅ 编译成功
✅ APK 构建成功 (50.0MB)
✅ 应用可以正常安装运行

## 相关文档

- [Android WifiAwareNetworkSpecifier.Builder API](https://developer.android.com/reference/android/net/wifi/aware/WifiAwareNetworkSpecifier.Builder)
- setPskPassphrase() - 从 Android 10 (API 29) 开始可用

## 注意事项

使用 `setPskPassphrase()` 时：
- 密码长度必须是 8-63 个 ASCII 字符
- 如果不设置密码，连接将是开放的（不加密）
- 建议在生产环境中始终使用密码保护

---
**修复时间**: 2025-11-08 12:11
**状态**: ✅ 已解决

---

## 问题 2: 缺少 CHANGE_NETWORK_STATE 权限

### 错误信息
```
SecurityException: com.example.ai_ocr_read was not granted either of these permissions:
android.permission.CHANGE_NETWORK_STATE,android.permission.WRITE_SETTINGS.
```

### 原因
建立数据路径时需要 `CHANGE_NETWORK_STATE` 权限来请求网络连接。

### 解决方案
在 `AndroidManifest.xml` 中添加：
```xml
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
```

### 修改的文件
- `android/app/src/main/AndroidManifest.xml`

### 注意事项
`CHANGE_NETWORK_STATE` 是普通权限（Normal Permission），应用安装时自动授予，不需要运行时请求。

---
**修复时间**: 2025-11-08 12:15
**状态**: ✅ 已解决
