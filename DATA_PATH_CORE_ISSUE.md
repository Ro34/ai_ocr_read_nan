# Wi-Fi Aware Data Path 核心问题与解决方案

## 根本问题

Wi-Fi Aware Data Path 的 `requestNetwork()` 需要**双方设备同时调用**才能成功建立连接。这是 Wi-Fi Aware 协议的设计特性。

### 为什么会失败？

```
设备 A 点击"建立数据路径"
  → 调用 requestNetwork()
  → 系统尝试与设备 B 协商
  → 设备 B 没有调用 requestNetwork()
  → 协商失败
  → "Network unavailable"
```

### 正确的流程

```
设备 A: 发送"请求建立数据路径"消息
  ↓
设备 B: 收到消息
  ↓
设备 A 和 B: 同时调用 requestNetwork()
  ↓
系统: 协商成功，建立连接
```

## 解决方案

### 方案 1: 消息协商（推荐）

1. **发送请求**
   ```kotlin
   // 设备 A 点击按钮
   sendMessage(peer, "DATA_PATH_REQUEST")
   delay(500)
   requestNetwork()
   ```

2. **自动响应**
   ```kotlin
   // 设备 B 收到消息
   onMessageReceived() {
       if (message == "DATA_PATH_REQUEST") {
           delay(500)
           requestNetwork() // 自动建立
       }
   }
   ```

3. **双方同时建立**
   - 设备 A: 500ms 后调用
   - 设备 B: 收到消息后 500ms 调用
   - 时间窗口重叠 → 成功

### 方案 2: 预建立模式

在发现时就建立连接（不推荐，消耗资源）:

```kotlin
onServiceDiscovered() {
    registerPeer()
    // 自动建立数据路径
    openDataPath(peerId)
}
```

### 方案 3: 手动协调

要求用户手动操作:
```
1. 设备 A: 点击"建立数据路径"
2. 设备 B: 在 3 秒内也点击"建立数据路径"
3. 双方同时请求 → 成功
```

## 当前状态分析

从日志看:
```
[NAN] 正在建立数据路径到 peer=1...
[NAN] 数据路径 peer=1 state=unavailable
```

**原因**: 只有设备 A 调用了 `requestNetwork()`，设备 B（peer=1）没有调用。

## 推荐实现

### 步骤 1: 添加协商消息类型

```kotlin
// 消息类型
const val MSG_TYPE_DATA_PATH_REQUEST = "DATA_PATH_REQUEST"
const val MSG_TYPE_DATA_PATH_ACK = "DATA_PATH_ACK"
```

### 步骤 2: 发送请求时先发消息

```kotlin
fun openDataPath(peerId: Int) {
    // 1. 发送请求消息
    sendMessage(peerId, MSG_TYPE_DATA_PATH_REQUEST)
    
    // 2. 延迟后建立
    scope.launch {
        delay(500)
        requestNetwork(peerId)
    }
}
```

### 步骤 3: 收到请求时自动响应

```kotlin
onMessageReceived(message) {
    if (message.type == MSG_TYPE_DATA_PATH_REQUEST) {
        // 发送确认
        sendMessage(peer, MSG_TYPE_DATA_PATH_ACK)
        
        // 自动建立
        scope.launch {
            delay(500)
            requestNetwork(peerId)
        }
    }
}
```

### 步骤 4: 时序图

```
时间轴    设备 A                    设备 B
------    -------                   -------
T+0s      点击"建立数据路径"
T+0.1s    发送 DATA_PATH_REQUEST →
T+0.2s                              收到请求
T+0.3s                              发送 DATA_PATH_ACK
T+0.5s    requestNetwork() ←
T+0.7s                              requestNetwork()
T+0.8s    ← 双方协商成功 →
T+1.0s    onAvailable 回调
```

## 为什么之前的实现失败？

1. **缺少协商机制**: 只有一方调用 `requestNetwork()`
2. **时序不匹配**: 两方调用时间差太大
3. **没有重试**: 失败后没有自动重试

## 新实现计划

### 修改清单

1. ✅ 定义协商消息类型
2. ⏳ 在 DataPathManager 中添加协商逻辑
3. ⏳ 在 NanManager 中处理协商消息
4. ⏳ 添加超时和重试机制
5. ⏳ 更新 UI 提示用户状态

### 预期效果

- ✅ 单方点击即可触发双方建立
- ✅ 自动协商，无需手动协调
- ✅ 提供清晰的状态反馈
- ✅ 失败后自动重试

## 临时解决方案

在实现自动协商之前，可以：

### 选项 1: 禁用数据路径，只用普通消息
```dart
setState(() => _autoUseDataPath = false);
```

### 选项 2: 手动协调（双设备测试）
```
1. 设备 A 和 B 都保持在应用界面
2. 设备 A 点击"建立数据路径"
3. 立即切换到设备 B
4. 3秒内点击设备 B 的"建立数据路径"
5. 观察是否成功
```

### 选项 3: 使用普通 NAN 消息
当前已实现自动降级:
```dart
if (textSize > limit) {
    if (canUseDataPath) {
        useDataPath()
    } else {
        useNormalMessage() // 自动截断
    }
}
```

## 下一步

实现自动协商机制，让数据路径建立对用户透明，无需手动协调。

---

**分析时间**: 2025-11-08 12:30
**状态**: 问题已定位，解决方案已明确
**优先级**: 高（影响核心功能）
