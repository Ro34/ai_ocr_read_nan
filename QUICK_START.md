# 快速开始：Wi-Fi Aware 数据路径功能

## 🚀 立即测试

### 1. 准备工作

**设备要求**:
- 2 台支持 Wi-Fi Aware 的 Android 设备（Android 10+）
- 推荐：Google Pixel 系列、Samsung Galaxy S9+、华为 Mate 10+

**软件要求**:
```bash
# 确认 Flutter 环境
flutter doctor

# 同步依赖
cd /Users/ro/Project/ai_ocr_read/ai_ocr_read
flutter pub get
```

### 2. 编译安装

```bash
# 清理构建缓存
flutter clean

# 编译并安装到设备
flutter run --release

# 或者构建 APK
flutter build apk --release
# APK 位置: build/app/outputs/flutter-apk/app-release.apk
```

### 3. 授予权限

**首次运行时需要授予**:
- ✅ 位置权限（必需）
- ✅ 附近设备权限（Android 13+）
- ✅ 相机权限（用于拍照）

**手动检查**:
```bash
# 确保定位服务已开启
adb shell settings get secure location_mode
# 输出应该是 3（高精度模式）

# 如果需要手动开启
adb shell settings put secure location_mode 3
```

### 4. 测试流程

#### 设备 A 和设备 B 同时操作：

**步骤 1: 配置房间码（两台设备使用相同房间码）**
```
1. 在"房间码"输入框输入: test123
2. 点击"保存房间码"
```

**步骤 2: 启动 NAN**
```
1. 点击"启动发布+订阅"
2. 等待状态变为"已订阅"
3. 观察"Peers"数量变为 1
4. 查看 NAN 日志确认发现成功
```

**步骤 3: 测试短消息（可选）**
```
1. 点击"广播 Hello"
2. 对方设备的 NAN 日志应显示收到消息
```

**步骤 4: 建立数据路径**
```
1. 在任一设备点击"建立数据路径"
2. 等待 2-3 秒
3. 观察"数据路径: 1/1"显示（绿色背景）
4. NAN 日志显示 "数据路径 available"
```

**步骤 5: 传输长文本**
```
方式 1 - 拍照识别后发送:
1. 点击"拍照"
2. 拍摄包含文字的照片
3. 点击"OCR 识别"或"VLM 分析"
4. 等待分析完成
5. 点击"发送分析结果"
6. 对方设备应收到完整文本

方式 2 - 直接测试长文本:
1. 点击"通过安全构建发送 2500B（会截断）"
2. 观察是否通过数据路径发送
```

### 5. 验证成功

**发送端应看到**:
```
NAN 日志:
- "通过数据路径发送 XXXX bytes 到 peer=1..."
- "数据已发送到 peer=1 (XXXX bytes)"
```

**接收端应看到**:
```
NAN 日志:
- "收到数据消息 from peer=1 (XXXX bytes): [内容预览]"
```

## 🔧 常见问题

### Q1: Peers 数量一直是 0？
**原因**: 
- 设备不支持 Wi-Fi Aware
- 房间码不匹配
- 权限未授予
- 定位服务未开启

**解决**:
```bash
# 检查设备是否支持
adb shell getprop ro.vendor.wifi.aware

# 检查权限
adb shell dumpsys package com.example.ai_ocr_read | grep permission

# 开启定位
在设置中手动开启定位服务
```

### Q2: 数据路径建立失败？
**原因**:
- Android 版本 < 10
- 设备距离过远（> 10米）
- Wi-Fi 信号弱

**解决**:
- 确认两台设备都是 Android 10+
- 将设备靠近（< 5米）
- 重新启动 NAN 并重试

### Q3: 无法接收消息？
**原因**:
- 数据路径未建立
- 协议不匹配

**解决**:
- 确认"数据路径: X/Y"中 Y > 0
- 重启应用重新建立连接
- 查看 logcat 详细错误

## 📊 调试命令

### 查看详细日志
```bash
# Flutter 日志
flutter logs | grep -E "NAN|DataPath"

# Android 原生日志
adb logcat | grep -E "NanManager|DataPathManager"

# Wi-Fi Aware 系统日志
adb logcat | grep WifiAware
```

### 启用详细调试
```bash
# 启用 Wi-Fi Aware 详细日志
adb shell setprop log.tag.WifiAware VERBOSE

# 重启应用查看详细信息
```

### 检查网络状态
```bash
# 查看 Wi-Fi Aware 状态
adb shell dumpsys wifi_aware

# 查看网络接口
adb shell ip link show
```

## 🎯 测试场景

### 场景 1: 基本功能测试
```
目标: 验证发现和短消息
预期: Peers > 0, 能收到 "hello" 消息
时间: 1-2 分钟
```

### 场景 2: 数据路径测试
```
目标: 建立连接并发送长文本
预期: 数据路径建立成功，能传输 > 2KB 文本
时间: 3-5 分钟
```

### 场景 3: 自动模式测试
```
目标: 验证智能选择传输方式
步骤:
1. 启用"自动数据路径"
2. 发送短文本 -> 应使用普通消息
3. 发送长文本 -> 应自动使用数据路径
预期: 系统自动选择最优方式
时间: 5-10 分钟
```

### 场景 4: 稳定性测试
```
目标: 测试连接稳定性
步骤:
1. 建立数据路径
2. 连续发送 10 条长文本
3. 移动设备改变距离
4. 重新靠近继续发送
预期: 连接自动恢复，消息不丢失
时间: 10-15 分钟
```

## 📈 性能基准

### 预期性能
| 指标 | 预期值 | 说明 |
|------|--------|------|
| 发现延迟 | < 5s | 从启动到发现 peer |
| 连接建立 | 1-3s | 数据路径建立时间 |
| 传输速度 | 1-10 Mbps | 取决于距离和环境 |
| 最大消息 | < 10MB | 建议限制 |
| 并发连接 | 3-5 | 理论支持更多 |

### 测试记录表

| 测试项 | 设备 A | 设备 B | 结果 | 备注 |
|--------|--------|--------|------|------|
| 设备型号 | _______ | _______ | - | - |
| Android 版本 | _______ | _______ | - | - |
| 发现延迟 | _______ s | _______ s | ✅/❌ | - |
| 数据路径建立 | _______ s | _______ s | ✅/❌ | - |
| 1KB 传输 | _______ ms | - | ✅/❌ | - |
| 10KB 传输 | _______ ms | - | ✅/❌ | - |
| 100KB 传输 | _______ ms | - | ✅/❌ | - |
| 1MB 传输 | _______ ms | - | ✅/❌ | - |

## 🎉 成功标志

如果看到以下现象，说明功能正常：

- ✅ 两台设备都能看到 "Peers: 1"
- ✅ 数据路径显示绿色 "数据路径: 1/1"
- ✅ 发送端显示 "数据已发送到 peer=X (YYYY bytes)"
- ✅ 接收端显示 "收到数据消息 from peer=X"
- ✅ 长文本（> 2KB）能完整传输
- ✅ 自动模式能正确选择传输方式

## 📞 获取帮助

### 日志收集
如果遇到问题，请收集以下信息：

```bash
# 1. 设备信息
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release

# 2. Wi-Fi Aware 支持
adb shell getprop ro.vendor.wifi.aware

# 3. 应用日志
flutter logs > flutter.log
adb logcat > android.log

# 4. NAN 日志（从应用内复制）
点击 "NAN 日志" 面板的 "复制" 按钮
```

### 问题报告
在提交问题时，请包含：
1. 设备型号和 Android 版本
2. 详细的复现步骤
3. 相关日志文件
4. 预期行为 vs 实际行为

## 🔄 重置和清理

### 重置应用状态
```bash
# 清除应用数据
adb shell pm clear com.example.ai_ocr_read

# 重新安装
flutter run --release
```

### 重置系统状态
```bash
# 关闭并重新开启 Wi-Fi
adb shell svc wifi disable
sleep 2
adb shell svc wifi enable

# 重启设备（如果需要）
adb reboot
```

## ✅ 测试完成清单

测试前请确认：
- [ ] 两台设备都安装了应用
- [ ] 所有权限都已授予
- [ ] Wi-Fi 和定位都已开启
- [ ] 设备距离 < 5 米
- [ ] 使用相同的房间码

测试中请验证：
- [ ] 能够发现对方设备
- [ ] 数据路径能够建立
- [ ] 短消息能正常发送（可选）
- [ ] 长文本能完整传输
- [ ] 自动模式正确工作
- [ ] UI 反馈及时准确

测试后请记录：
- [ ] 性能数据（延迟、速度）
- [ ] 任何错误或警告
- [ ] 用户体验反馈
- [ ] 改进建议

---

**祝测试顺利！如有问题，请参考完整文档 `DATA_PATH_USAGE.md`**
