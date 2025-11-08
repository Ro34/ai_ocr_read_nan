# Android 权限清单

## Wi-Fi Aware Data Path 所需权限

### 普通权限（Normal Permissions）
安装时自动授予，无需运行时请求：

```xml
<!-- 基础网络权限 -->
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
```

### 危险权限（Dangerous Permissions）
需要在运行时请求用户授予：

```xml
<!-- 位置权限（Wi-Fi Aware 必需） -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<!-- Android 13+ 附近设备权限 -->
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />

<!-- 相机权限（用于拍照功能） -->
<uses-permission android:name="android.permission.CAMERA" />
```

### 硬件特性声明

```xml
<!-- Wi-Fi Aware 硬件支持（可选，不强制） -->
<uses-feature android:name="android.hardware.wifi.aware" android:required="false" />
```

## 权限说明

### CHANGE_NETWORK_STATE
- **用途**: 允许应用通过 ConnectivityManager 请求网络连接
- **类型**: Normal Permission
- **必需性**: ✅ 必需（用于建立 Wi-Fi Aware Data Path）
- **授予方式**: 安装时自动授予

### ACCESS_FINE_LOCATION
- **用途**: Wi-Fi Aware 需要位置权限才能发现附近设备
- **类型**: Dangerous Permission
- **必需性**: ✅ 必需
- **授予方式**: 运行时弹窗请求
- **特殊要求**: 位置服务必须开启

### NEARBY_WIFI_DEVICES (Android 13+)
- **用途**: Android 13+ 使用此权限替代位置权限访问 Wi-Fi
- **类型**: Dangerous Permission
- **必需性**: ✅ Android 13+ 必需
- **授予方式**: 运行时弹窗请求
- **降级**: 如果拒绝，仍可通过 ACCESS_FINE_LOCATION 工作

### CHANGE_WIFI_STATE
- **用途**: 允许应用启动/停止 Wi-Fi，修改 Wi-Fi 配置
- **类型**: Normal Permission
- **必需性**: ✅ 必需（Wi-Fi Aware 操作需要）
- **授予方式**: 安装时自动授予

## 权限请求流程

### 代码中的实现 (lib/main.dart)

```dart
Future<bool> _ensureNanPermissions() async {
  // 1. 请求位置权限
  final loc = await Permission.locationWhenInUse.request();
  
  // 2. 请求附近设备权限（Android 13+）
  PermissionStatus nearbyStatus = PermissionStatus.granted;
  try {
    nearbyStatus = await Permission.nearbyWifiDevices.request();
  } catch (_) {}
  
  // 3. 检查是否授予
  final granted = (loc.isGranted || loc.isLimited) && 
                  (nearbyStatus.isGranted || nearbyStatus.isLimited || nearbyStatus.isDenied);
  
  // 4. 如果永久拒绝，引导用户到设置
  if (!granted) {
    if (loc.isPermanentlyDenied || nearbyStatus.isPermanentlyDenied) {
      await openAppSettings();
    }
  }
  
  return granted;
}
```

## 常见问题

### Q1: 为什么需要位置权限？
Wi-Fi Aware/NAN 使用 Wi-Fi 扫描来发现附近设备，而 Wi-Fi 扫描结果可以用于定位，因此系统要求位置权限。

### Q2: 必须开启位置服务吗？
是的。即使授予了位置权限，如果位置服务（GPS）关闭，Wi-Fi Aware 也无法工作。

### Q3: Android 13+ 不授予 NEARBY_WIFI_DEVICES 可以吗？
可以，但会降级使用 ACCESS_FINE_LOCATION。建议同时请求两者。

### Q4: 为什么需要 CHANGE_NETWORK_STATE？
建立 Wi-Fi Aware Data Path 时，需要通过 ConnectivityManager.requestNetwork() 请求网络连接，这需要 CHANGE_NETWORK_STATE 权限。

### Q5: WRITE_SETTINGS 权限需要吗？
不需要。错误信息中提到的 WRITE_SETTINGS 是系统的备选权限，我们只需要 CHANGE_NETWORK_STATE。

## 权限验证

### 检查权限是否授予

```bash
# 查看应用所有权限
adb shell dumpsys package com.example.ai_ocr_read | grep permission

# 检查特定权限
adb shell dumpsys package com.example.ai_ocr_read | grep "android.permission.CHANGE_NETWORK_STATE"
```

### 手动授予权限（测试用）

```bash
# 授予位置权限
adb shell pm grant com.example.ai_ocr_read android.permission.ACCESS_FINE_LOCATION

# 授予附近设备权限（Android 13+）
adb shell pm grant com.example.ai_ocr_read android.permission.NEARBY_WIFI_DEVICES
```

### 检查位置服务状态

```bash
# 查看位置服务是否开启
adb shell settings get secure location_mode
# 输出: 0=关闭, 3=高精度模式

# 手动开启位置服务
adb shell settings put secure location_mode 3
```

## 最佳实践

1. **安装时**:
   - 所有 Normal Permissions 自动授予
   - 无需任何操作

2. **首次运行时**:
   - 在启动 NAN 之前请求 Dangerous Permissions
   - 提供清晰的权限说明
   - 如果拒绝，友好提示功能受限

3. **权限被拒绝时**:
   - 显示为什么需要这些权限
   - 提供"去设置"按钮
   - 允许用户在不授予权限的情况下使用其他功能

4. **Android 13+ 特殊处理**:
   - 优先请求 NEARBY_WIFI_DEVICES
   - 失败时降级到 ACCESS_FINE_LOCATION
   - 两者至少需要一个

## 权限对照表

| 权限 | API 级别 | 类型 | 必需性 | 用途 |
|------|---------|------|--------|------|
| INTERNET | All | Normal | ✅ | 后端 API 调用 |
| ACCESS_WIFI_STATE | All | Normal | ✅ | 读取 Wi-Fi 状态 |
| CHANGE_WIFI_STATE | All | Normal | ✅ | Wi-Fi Aware 操作 |
| CHANGE_NETWORK_STATE | All | Normal | ✅ | 请求数据路径网络 |
| ACCESS_FINE_LOCATION | All | Dangerous | ✅ | Wi-Fi 扫描/发现 |
| NEARBY_WIFI_DEVICES | 33+ | Dangerous | ✅ (13+) | Wi-Fi 扫描（新） |
| CAMERA | All | Dangerous | 📷 | 拍照功能 |

## 完整 AndroidManifest.xml 权限部分

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- 基础网络权限 -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
    
    <!-- Wi-Fi Aware 相关权限 -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
    
    <!-- 硬件特性 -->
    <uses-feature android:name="android.hardware.wifi.aware" android:required="false" />
    
    <application>
        <!-- ... -->
    </application>
</manifest>
```

---

**更新时间**: 2025-11-08
**适用版本**: Android 10+ (API 29+)
