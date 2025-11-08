# Wi-Fi Aware Data Path 连接策略

## 问题背景

Wi-Fi Aware Data Path 需要两个设备建立点对点的网络连接。最初的实现只使用了 initiator（发起方）模式，导致单方请求时出现 "Network unavailable" 错误。

## 解决方案：双模式连接

### 策略概述

采用**同时作为服务端和客户端**的混合模式：

1. **服务端模式（Server Mode）**
   - 创建 ServerSocket 监听任意端口
   - 等待对端连接（10秒超时）
   - 适用于被动接受连接

2. **客户端模式（Client Mode）**  
   - 延迟 1 秒后尝试主动连接
   - 通过 IPv6 Link-Local 地址连接对端
   - 适用于主动发起连接

3. **竞争机制**
   - 两种模式同时运行
   - 任一模式成功即取消另一模式
   - 确保至少一方能成功建立连接

### 连接流程

```
设备 A                          设备 B
  |                               |
  | 1. 发现对方（NAN）             |
  |<----------------------------->|
  |                               |
  | 2. 点击"建立数据路径"          |
  |                               |
  | 3. 请求网络                    |
  | ConnectivityManager           |
  |   .requestNetwork()           |
  |                               |
  | 4. onAvailable 回调            |
  |                               |
  | 5a. 启动 ServerSocket         | 5a. 启动 ServerSocket
  |     (监听端口 X)              |     (监听端口 Y)
  |                               |
  | 5b. 延迟 1 秒                 | 5b. 延迟 1 秒
  |                               |
  | 6. 尝试连接到 B:Y             | 6. 尝试连接到 A:X
  |                               |
  | 7. 竞争结果：                 |
  |    - A 成功连接到 B (客户端)  |
  |    或                          |
  |    - B 成功连接到 A (服务端)  |
  |                               |
  | 8. Socket 建立                |
  |<=============================>|
  |                               |
```

### 技术细节

#### IPv6 Link-Local 地址

Wi-Fi Aware Data Path 使用 IPv6 点对点连接：

```kotlin
val linkProperties = connectivityManager.getLinkProperties(network)
val addresses = linkProperties?.linkAddresses

for (linkAddr in addresses) {
    val addr = linkAddr.address
    if (addr is Inet6Address && addr.isLinkLocalAddress) {
        // 使用此地址连接
        val socket = Socket()
        socket.connect(InetSocketAddress(addr, remotePort), 5000)
    }
}
```

#### 超时处理

```kotlin
// 服务端接受超时：10 秒
withTimeout(10000) {
    val socket = serverSocket.accept()
}

// 客户端连接超时：5 秒
socket.connect(address, 5000)
```

#### 竞争处理

```kotlin
// 服务端协程
val acceptJob = launch { /* ... */ }

// 客户端协程
launch {
    delay(1000) // 给服务端先启动
    if (clientConnectSuccess) {
        acceptJob.cancel() // 取消服务端
        serverSocket.close()
    }
}
```

## 为什么需要双模式？

### Wi-Fi Aware 的特殊性

1. **无中心化**: 没有明确的服务端/客户端角色
2. **对等连接**: 两个设备地位相等
3. **动态协商**: 连接建立是双方协商的结果

### 单模式的问题

- **只用 Initiator**: 对方必须是 Responder，不灵活
- **只用 ServerSocket**: 双方都监听，永远无法连接
- **只用 ClientSocket**: 双方都尝试连接，但没有监听者

### 双模式的优势

- ✅ 任一设备点击"建立数据路径"都能成功
- ✅ 不需要预先协商谁是服务端
- ✅ 提高连接成功率
- ✅ 适应不同的网络环境

## 当前实现

### DataPathManager.kt 关键代码

```kotlin
override fun onAvailable(network: Network) {
    scope.launch {
        // 1. 创建 ServerSocket
        val serverSocket = ServerSocket(0)
        val localPort = serverSocket.localPort
        
        // 2. 服务端模式
        val acceptJob = launch {
            withTimeout(10000) {
                val socket = serverSocket.accept()
                // 连接成功，保存 socket
                dataSockets[peerId] = socket
            }
        }
        
        // 3. 客户端模式
        launch {
            delay(1000)
            // 尝试连接到对端
            val clientSocket = Socket()
            clientSocket.connect(remoteAddress, 5000)
            
            // 成功则取消服务端
            acceptJob.cancel()
            serverSocket.close()
            dataSockets[peerId] = clientSocket
        }
    }
}
```

## 测试验证

### 单设备测试

即使只有一台设备，现在也能：
- ✅ 成功创建 ServerSocket
- ✅ 进入监听状态
- ⏳ 等待对端连接（10秒后超时）

预期日志：
```
[NAN] ServerSocket listening on port 12345 for peer=1
[NAN] 数据路径 peer=1 state=listening
[NAN] Accept timeout for peer 1  (10秒后)
```

### 双设备测试

两台设备都点击"建立数据路径"：
- ✅ 至少一方成功建立连接
- ✅ Socket 可用于双向通信
- ✅ 数据传输正常

预期日志（成功）：
```
设备 A:
[NAN] ServerSocket listening on port 12345
[NAN] Accepted connection from peer 1
[NAN] 数据路径 peer=1 state=available role=server

设备 B:
[NAN] ServerSocket listening on port 23456
[NAN] Connected as client to peer 1
[NAN] 数据路径 peer=1 state=available role=client
```

## 改进点

### 已实现
- ✅ 双模式连接策略
- ✅ 超时处理
- ✅ 竞争机制
- ✅ IPv6 地址解析

### 待优化
- ⏳ 重连机制
- ⏳ 连接优先级（服务端优先或客户端优先）
- ⏳ 端口复用
- ⏳ 连接池管理

## 故障排查

### 依然出现 "Network unavailable"

**可能原因**:
1. 对端设备未运行应用
2. 对端设备未点击"建立数据路径"
3. 设备不支持 Wi-Fi Aware Data Path
4. 网络环境问题

**解决方法**:
1. 确保两台设备都运行应用
2. 两台设备都点击"建立数据路径"
3. 检查设备是否 Android 10+
4. 确保两台设备距离 < 10米

### "Accept timeout"

**原因**: 10秒内未收到对端连接

**正常情况**:
- 单设备测试时预期行为
- 对端未建立数据路径

**异常情况**:
- 双设备都超时 → 检查网络配置
- IPv6 不可用 → 检查系统设置

### "Client connect failed"

**原因**: 无法连接到对端

**可能原因**:
1. 获取不到 IPv6 地址
2. 对端端口未监听
3. 防火墙阻止

**调试方法**:
```bash
# 查看网络接口
adb shell ip -6 addr show

# 查看连接
adb shell ss -6 -t
```

## 参考资料

- [Android Wi-Fi Aware Data Path](https://developer.android.com/develop/connectivity/wifi/wifi-aware#data-path)
- [ServerSocket API](https://developer.android.com/reference/java/net/ServerSocket)
- [IPv6 Link-Local](https://en.wikipedia.org/wiki/Link-local_address#IPv6)

---

**更新时间**: 2025-11-08 12:20
**版本**: 2.0 - 双模式连接
**状态**: 测试中
