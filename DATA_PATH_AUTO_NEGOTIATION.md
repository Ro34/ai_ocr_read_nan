# 数据路径自动协商机制

## 功能概述

实现了基于 NAN 消息的自动协商机制，解决 Wi-Fi Aware Data Path 需要双方同时调用 `requestNetwork()` 的问题。

## 核心原理

**问题背景**：
- Wi-Fi Aware Data Path 不是传统的客户端-服务端模式
- 两个设备必须在短时间窗口内同时调用 `requestNetwork()`
- 单方调用会导致 "Network unavailable" 错误

**解决方案**：
1. 发起方先通过 NAN 消息发送 `DATA_PATH_REQUEST:<deviceId>`
2. 接收方自动响应：
   - 发送 `DATA_PATH_ACK` 确认消息
   - 延迟 800ms 后自动调用 `openDataPath()`
3. 发起方延迟 1500ms 后调用 `requestNetwork()`
4. 双方时间窗口重叠，成功建立连接

## 代码修改

### 1. DataPathManager.kt

#### 新增协商方法

```kotlin
/**
 * 发送协商请求消息到对端
 */
private fun sendNegotiationRequest(peerInfo: PeerInfo) {
    val deviceId = Settings.Secure.getString(
        context.contentResolver,
        Settings.Secure.ANDROID_ID
    ) ?: "unknown"
    val message = "DATA_PATH_REQUEST:$deviceId"
    
    // 根据 discoverySession 类型发送消息
    when (val session = peerInfo.discoverySession) {
        is PublishDiscoverySession -> {
            session.sendMessage(peerInfo.peerHandle, 0, message.toByteArray())
        }
        is SubscribeDiscoverySession -> {
            session.sendMessage(peerInfo.peerHandle, 0, message.toByteArray())
        }
    }
    
    // 延迟 1500ms 后继续建立连接
    handler.postDelayed({
        continueOpenDataPath(peerInfo)
    }, 1500)
}

/**
 * 继续建立数据路径（在发送协商请求后）
 */
private fun continueOpenDataPath(peerInfo: PeerInfo) {
    // 如果已经建立连接，跳过
    if (dataSockets.containsKey(peerInfo.peerId)) return
    
    // 执行实际的网络请求
    executeNetworkRequest(peerInfo)
}

/**
 * 执行实际的网络请求（从 openDataPath 中提取）
 */
private fun executeNetworkRequest(peerInfo: PeerInfo) {
    // 构建 NetworkSpecifier
    val builder = WifiAwareNetworkSpecifier.Builder(
        peerInfo.discoverySession,
        peerInfo.peerHandle
    )
    
    // 设置端口和密码
    // ...
    
    // 注册 NetworkCallback
    val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            // 获取 IPv6 地址并建立 Socket 连接
            // ...
        }
    }
    
    connectivityManager.requestNetwork(networkRequest, callback)
}
```

#### 修改 openDataPath 方法

```kotlin
fun openDataPath(
    peerId: Int,
    passphrase: String?,
    port: Int = 0,
    onSuccess: (() -> Unit)? = null,
    onError: ((String) -> Unit)? = null
) {
    // 保存参数到 PeerInfo
    peerInfo.passphrase = passphrase
    peerInfo.port = if (port > 0) port else 8888
    
    // 发送协商请求（后续会自动调用 executeNetworkRequest）
    sendNegotiationRequest(peerInfo)
}
```

#### 更新 PeerInfo 数据类

```kotlin
data class PeerInfo(
    val peerId: Int,
    val peerHandle: PeerHandle,
    val deviceId: String?,
    val discoverySession: DiscoverySession,
    var publishSession: PublishDiscoverySession? = null,
    var passphrase: String? = null,
    var port: Int = 0
)
```

### 2. NanManager.kt

#### 自动响应协商请求

在 `onMessageReceived` 回调中添加：

```kotlin
if (text.startsWith("DATA_PATH_REQUEST:")) {
    val parts = text.split(":")
    if (parts.size >= 2) {
        val requesterDevId = parts[1]
        Log.d(tag, "Received DATA_PATH_REQUEST from $requesterDevId")
        
        // 注册 peer（如果尚未注册）
        val peerId = dataPathManager?.registerPeer(peerHandle, requesterDevId, session)
        
        if (peerId != null) {
            // 发送 ACK
            try {
                val ackMsg = "DATA_PATH_ACK"
                session?.sendMessage(peerHandle, 0, ackMsg.toByteArray())
            } catch (_: Throwable) {}
            
            // 延迟 800ms 后自动建立数据路径
            handler.postDelayed({
                dataPathManager?.openDataPath(
                    peerId = peerId,
                    passphrase = "aiocr_secure",
                    onSuccess = {
                        Log.d(tag, "Auto data path established for peer $peerId")
                    },
                    onError = { err ->
                        Log.w(tag, "Auto data path failed for peer $peerId: $err")
                    }
                )
            }, 800)
        }
    }
    return // 不作为普通消息处理
}
```

## 时序图

```
发起方 (Device A)                          接收方 (Device B)
    |                                            |
    | ------ DATA_PATH_REQUEST:deviceA -------> |
    |                                            |
    |                                            | 收到请求，注册 peer
    |                                            |
    | <-------- DATA_PATH_ACK ----------------- |
    |                                            |
    |                                            | [800ms 延迟]
    |                                            |
    |                                            | openDataPath()
    |                                            | -> sendNegotiationRequest()
    |                                            | -> [1500ms 延迟]
    |                                            | -> executeNetworkRequest()
    |                                            | -> requestNetwork()
    |                                            |
    | [1500ms 延迟]                              |
    |                                            |
    | continueOpenDataPath()                     |
    | -> executeNetworkRequest()                 |
    | -> requestNetwork()                        |
    |                                            |
    | <========== 数据路径建立成功 =============> |
    |                                            |
    | Socket 连接建立                            |
    | 开始传输长文本                             |
```

## 关键时间参数

- **接收方响应延迟**: 800ms
  - 接收到 `DATA_PATH_REQUEST` 后，延迟 800ms 调用 `openDataPath()`
  - 目的：给发送方时间接收 ACK

- **发起方网络请求延迟**: 1500ms
  - 发送 `DATA_PATH_REQUEST` 后，延迟 1500ms 调用 `requestNetwork()`
  - 目的：等待接收方准备就绪

- **时间窗口重叠**: ~500ms
  - 接收方在 800ms + 1500ms = 2300ms 时调用 `requestNetwork()`
  - 发起方在 1500ms 时调用 `requestNetwork()`
  - 两者有 ~800ms 的重叠窗口，足够系统建立连接

## 测试步骤

### 单设备测试（验证消息流程）

1. 启动应用，查看日志：
   ```
   Sending negotiation request to peer 1: DATA_PATH_REQUEST:abc123
   ```

2. 自动回环响应（需要第二台设备才能真正测试）

### 双设备测试（完整测试）

#### Device A:
1. 启动应用，等待发现 Device B
2. 点击"发送分析到 Peer 1"
3. 查看日志：
   ```
   Opening data path to peer 1 as initiator
   Sending negotiation request to peer 1: DATA_PATH_REQUEST:deviceA
   Received DATA_PATH_ACK
   Continuing to establish data path for peer 1
   Network available for peer 1
   IPv6 address: fe80::xxxx
   Data path established for peer 1
   ```

#### Device B:
1. 启动应用，等待发现 Device A
2. 自动响应（无需手动操作）
3. 查看日志：
   ```
   Received DATA_PATH_REQUEST from deviceA
   Auto-responding to DATA_PATH_REQUEST, peerId=1
   Auto data path established for peer 1
   ```

## 故障排查

### 问题 1: 仍然显示 "Network unavailable"

**可能原因**：
- 时间窗口不够（延迟参数需调整）
- 网络环境问题（Wi-Fi Aware 未正常工作）
- 设备不支持 Wi-Fi Aware Data Path

**解决方法**：
1. 调整 `sendNegotiationRequest` 中的延迟：1500ms → 2000ms
2. 调整 NanManager 中的延迟：800ms → 1000ms
3. 查看系统日志：`adb logcat | grep -E "Aware|DataPath"`

### 问题 2: 消息发送失败

**可能原因**：
- discoverySession 为 null
- NAN 消息队列已满
- 对端未正常响应

**解决方法**：
1. 确保在 `onServiceDiscovered` 后再调用
2. 检查日志中的 "Failed to send negotiation request"
3. 减少消息发送频率

### 问题 3: ACK 未收到

**可能原因**：
- 对端处理消息太慢
- 网络延迟较高
- 消息被过滤

**解决方法**：
1. 增加发起方的延迟时间（1500ms → 2000ms）
2. 检查 NanManager 中的消息过滤逻辑
3. 确保 ACK 消息不被作为普通消息处理

## 性能优化

### 减少延迟

如果网络环境良好，可以减少延迟时间：

```kotlin
// 接收方延迟
handler.postDelayed({...}, 500) // 从 800ms 降低到 500ms

// 发起方延迟
handler.postDelayed({...}, 1000) // 从 1500ms 降低到 1000ms
```

### 增加可靠性

如果网络环境不稳定，可以增加重试机制：

```kotlin
private var retryCount = 0
private val maxRetries = 3

private fun continueOpenDataPath(peerInfo: PeerInfo) {
    if (dataSockets.containsKey(peerInfo.peerId)) return
    
    executeNetworkRequest(peerInfo)
    
    // 5秒后检查是否成功，失败则重试
    handler.postDelayed({
        if (!dataSockets.containsKey(peerInfo.peerId) && retryCount < maxRetries) {
            retryCount++
            Log.w(tag, "Retrying data path connection, attempt $retryCount")
            sendNegotiationRequest(peerInfo)
        }
    }, 5000)
}
```

## 下一步

1. **双设备测试**：使用两台 Android 10+ 设备进行实际测试
2. **优化时间参数**：根据测试结果调整延迟时间
3. **添加重试机制**：处理网络不稳定情况
4. **完善 UI 反馈**：显示协商状态（"正在协商..."、"等待对端响应..."）

## 相关文档

- [DATA_PATH_USAGE.md](./DATA_PATH_USAGE.md) - 数据路径使用指南
- [DATA_PATH_CORE_ISSUE.md](./DATA_PATH_CORE_ISSUE.md) - 核心问题分析
- [QUICK_START.md](./QUICK_START.md) - 快速测试指南
