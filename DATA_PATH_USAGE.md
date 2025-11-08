# Wi-Fi Aware 数据路径使用指南

本项目已实现基于 Wi-Fi Aware Data Path 的长文本传输功能，解决了 NAN 协议发现消息长度限制（约 255 字节）的问题。

## 功能概述

### 1. 发现阶段（Discovery Phase）
- 使用 NAN publish/subscribe 进行设备发现
- 交换设备 ID、房间码等少量元数据
- 自动注册已发现的 peer 到数据路径管理器

### 2. 数据路径建立（Data Path Establishment）
- 使用 `WifiAwareNetworkSpecifier` 和 `NetworkRequest` 建立点对点连接
- 支持密码保护（passphrase）
- 自动管理网络连接生命周期

### 3. 大数据传输（Large Data Transfer）
- 通过 Socket 连接传输任意长度的文本
- 使用长度前缀协议（4 字节网络序 + UTF-8 数据）
- 支持并发多个 peer 连接

## 使用方法

### 自动模式（推荐）

在应用中启用"自动数据路径"开关（默认启用），系统会自动判断：

1. 当文本大小超过 NAN 消息限制的 80% 时
2. 自动尝试建立数据路径
3. 建立成功后通过数据路径发送
4. 失败则降级到普通消息（会被截断）

```dart
// 自动模式已默认启用
setState(() => _autoUseDataPath = true);

// 正常发送，系统自动选择最佳方式
await _sendAnalysisOverNan();
```

### 手动模式

#### 步骤 1: 启动 NAN 发现
```dart
// 启动发布和订阅
await _startNan();
// 等待发现 peers（监听 'peerRegistered' 事件）
```

#### 步骤 2: 建立数据路径
```dart
// 建立到第一个可用 peer 的数据路径
await _openDataPathToFirstPeer();

// 或指定 peerId
await _nan.invokeMethod('openDataPath', {
  'peerId': targetPeerId,
  'passphrase': 'your_secure_passphrase',
});
```

#### 步骤 3: 发送长文本
```dart
// 等待数据路径建立（监听 'dataPath' 事件 state='available'）
// 然后发送
await _sendViaDataPath();

// 或直接调用
await _nan.invokeMethod('sendLargeText', {
  'peerId': targetPeerId,
  'text': yourLongText,
});
```

#### 步骤 4: 关闭连接（可选）
```dart
// 关闭指定 peer 的数据路径
await _nan.invokeMethod('closeDataPath', {'peerId': peerId});

// 或关闭所有
await _closeAllDataPaths();
```

## 事件监听

应用会接收以下数据路径相关事件：

### peerRegistered
```dart
{
  "type": "peerRegistered",
  "peerId": 1,
  "deviceId": "dev-xxx"
}
```

### dataPath
```dart
{
  "type": "dataPath",
  "state": "available", // available | unavailable | lost | closed
  "peerId": 1,
  "role": "initiator"   // initiator | responder
}
```

### dataMessage
```dart
{
  "type": "dataMessage",
  "peerId": 1,
  "text": "接收到的长文本内容",
  "bytes": 5000
}
```

### dataSent
```dart
{
  "type": "dataSent",
  "peerId": 1,
  "bytes": 5000
}
```

### dataSendError
```dart
{
  "type": "dataSendError",
  "peerId": 1,
  "error": "错误信息"
}
```

## API 参考

### Android 原生方法

#### `listDataPathPeers()`
返回所有已注册的 peer 列表及其状态。

```kotlin
Result: List<Map<String, Any?>>
[
  {
    "peerId": 1,
    "deviceId": "dev-xxx",
    "hasDataPath": true
  }
]
```

#### `openDataPath(peerId: Int, passphrase: String?)`
建立到指定 peer 的数据路径。

**参数:**
- `peerId`: 目标 peer ID（从 peerRegistered 事件获取）
- `passphrase`: 可选的连接密码（推荐使用）

**返回:** 异步，通过 `dataPath` 事件返回结果

#### `sendLargeText(peerId: Int, text: String)`
通过已建立的数据路径发送长文本。

**参数:**
- `peerId`: 目标 peer ID
- `text`: 要发送的文本（无长度限制）

**返回:** 异步，通过 `dataSent` 或 `dataSendError` 事件返回结果

#### `closeDataPath(peerId: Int)`
关闭指定 peer 的数据路径。

**参数:**
- `peerId`: 目标 peer ID

## 技术细节

### 协议格式

数据路径使用简单的长度前缀协议：

```
[4 字节长度（网络字节序大端）][N 字节 UTF-8 数据]
```

例如，发送 "Hello" (5 字节):
```
00 00 00 05 48 65 6C 6C 6F
```

### 安全性

1. **密码保护**: 建议使用 passphrase 参数加密数据路径
2. **房间隔离**: 通过房间码（matchFilter）限制设备发现范围
3. **长度校验**: 接收端会验证消息长度，拒绝超大消息（>10MB）

### 性能考虑

1. **建立延迟**: 数据路径建立通常需要 1-3 秒
2. **传输速度**: 取决于 Wi-Fi Aware 链路质量，通常可达 1-10 Mbps
3. **并发连接**: 理论上可支持多个并发 peer 连接
4. **资源管理**: 应及时关闭不需要的连接以释放资源

### 系统要求

- **最低 Android 版本**: Android 10 (API 29)
  - Android 8/9 支持基本 NAN 功能，但不支持数据路径
- **硬件要求**: 设备必须支持 Wi-Fi Aware/NAN
- **权限要求**: 
  - `ACCESS_FINE_LOCATION`
  - `NEARBY_WIFI_DEVICES` (Android 13+)
  - 位置服务必须开启

## 故障排查

### 数据路径建立失败

**问题**: 收到 `dataPath` 事件 state='unavailable'

**可能原因:**
1. 对端设备不支持数据路径（API < 29）
2. 网络环境不稳定
3. 密码不匹配（如果使用了 passphrase）
4. 设备距离过远或信号弱

**解决方案:**
1. 检查两端设备系统版本
2. 确保设备距离足够近（<10米）
3. 确认双方使用相同的 passphrase
4. 降级到普通 NAN 消息（会被截断）

### 发送失败

**问题**: 收到 `dataSendError` 事件

**可能原因:**
1. 数据路径已断开
2. 网络超时
3. 内存不足

**解决方案:**
1. 检查 `_dataPathReady` 集合确认连接状态
2. 重新建立数据路径
3. 分批发送大文本

### 无法接收消息

**问题**: 对端无法收到 `dataMessage` 事件

**可能原因:**
1. 读取协程未正常启动
2. 数据格式不匹配
3. 编码问题

**解决方案:**
1. 检查 NAN 日志中的 "Reading loop" 相关信息
2. 确保双方使用相同的协议版本
3. 验证 UTF-8 编码正确

## 示例场景

### 场景 1: OCR 结果共享

```dart
// 1. 拍照并进行 OCR 识别
await _analyzeWithOcr();

// 2. 启动 NAN（如果尚未启动）
await _startNan();

// 3. 自动发送（会自动判断是否需要数据路径）
await _sendAnalysisOverNan();
```

### 场景 2: 大文件传输准备

```dart
// 1. 提前建立数据路径
await _openDataPathToFirstPeer();

// 2. 等待连接就绪
await Future.delayed(Duration(seconds: 2));

// 3. 发送大量数据
if (_dataPathReady.isNotEmpty) {
  await _sendViaDataPath();
}
```

### 场景 3: 多设备广播

```dart
// 遍历所有已连接的 peer
for (final peerId in _dataPathReady) {
  await _nan.invokeMethod('sendLargeText', {
    'peerId': peerId,
    'text': broadcastMessage,
  });
}
```

## 最佳实践

1. **优先使用自动模式**: 让系统自动选择传输方式
2. **及时关闭连接**: 不使用时关闭数据路径以节省资源
3. **处理错误**: 监听所有错误事件并提供降级方案
4. **限制消息大小**: 即使支持长文本，也应设置合理上限（如 1MB）
5. **显示进度**: 对于大文本传输，显示进度提示以提升用户体验

## 参考资料

- [Android Wi-Fi Aware 官方文档](https://developer.android.com/develop/connectivity/wifi/wifi-aware)
- [Wi-Fi Alliance Neighbor Awareness Networking](https://www.wi-fi.org/discover-wi-fi/wi-fi-aware)
- 本项目文档: `nan_data_link.md`
