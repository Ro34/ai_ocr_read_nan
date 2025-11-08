根据您提供的 Android 开发者文档（Wi-Fi Aware/NAN），您遇到的问题是 NAN 协议的设计特性所致。

NAN 协议（在 Android 中实现为 Wi-Fi Aware）的**发现和消息传递机制（Messaging）**，其目的并非用于传输大量数据。

正如文档中所指出的，通过 `sendMessage()` 发送的消息主要用于**轻量级通信**，例如服务发现后的握手或交换少量配置信息。这些消息的长度受到严格限制，**大约在 255 字节左右**（您可以通过调用 `getMaxServiceSpecificInfoLength()` 来获取确切的最大长度）。

因此，任何“长文本”都将超出这个限制，导致无法发送。

### 解决方案：建立数据路径（Data Path）

要解决这个问题，您不应该使用 NAN 的 `sendMessage()` 来传输长文本。正确的做法是，在设备通过 NAN 互相发现之后，**在它们之间建立一个专用的、高带宽的数据路径（Data Path）**。

这个数据路径本质上是一个点对点的 Wi-Fi 连接（类似于 Wi-Fi Direct），它允许您像使用标准 `Socket` 一样进行高速、可靠的数据传输。

根据 Android 开发者文档，标准流程如下：

1.  **服务发现**：

      * 发布方（Publisher）使用 `publish()` 来广播服务。
      * 订阅方（Subscriber）使用 `subscribe()` 来发现服务。

2.  **建立连接（数据路径）**：

      * 一旦订阅方通过 `onServiceDiscovered()` 找到了发布方（获得了 `PeerHandle`），它就可以请求建立一个网络连接。
      * 订阅方创建一个 `WifiAwareNetworkSpecifier`，指定它想要连接的对等方（PeerHandle）。
      * 然后，它构建一个 `NetworkRequest`，并将此请求提交给 `ConnectivityManager`。

    <!-- end list -->

    ```kotlin
    // 示例代码（在订阅方）
    val networkSpecifier = WifiAwareNetworkSpecifier.Builder(discoverySession, peerHandle)
        .build()

    val networkRequest = NetworkRequest.Builder()
        .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
        .setNetworkSpecifier(networkSpecifier)
        .build()

    val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            // 步骤 3：网络连接已可用！
            // 现在可以使用这个 'network' 对象来打开 Socket
            // ...
        }
        // ... 其他回调
    }

    connectivityManager.requestNetwork(networkRequest, networkCallback)
    ```

3.  **传输数据（长文本）**：

      * **在发布方**：在请求连接之前或之后，发布方需要打开一个 `ServerSocket` 来监听传入的连接。
      * **在订阅方**：当 `ConnectivityManager.NetworkCallback` 中的 `onAvailable(Network network)` 被调用时，系统已经成功建立了数据路径。
      * 此时，订阅方使用返回的 `Network` 对象来打开一个 `Socket`，连接到发布方的 `ServerSocket`。

    <!-- end list -->

    ```kotlin
    // 示例代码（在订阅方的 onAvailable 回调中）
    override fun onAvailable(network: Network) {
        // network.getSocketFactory() 已被弃用，
        // 推荐使用 network.bindSocket() 或直接打开 Socket
        try {
            // 获取发布方的 IP 地址（通常在建立连接时通过轻量级消息交换）
            // 或者，发布方在 `onNetworkRequested` 回调中获取 IP
            val publisherIpAddress = ... 
            val publisherPort = ...

            // 使用这个 'network' 对象来创建 Socket
            val socket = network.socketFactory.createSocket(publisherIpAddress, publisherPort)

            // 步骤 4：通过 Socket 传输长文本
            val outputStream = socket.getOutputStream()
            outputStream.write("这里是您的任意长度的文本...".toByteArray())
            // ...
            
        } catch (e: Exception) {
            // 处理异常
        }
    }
    ```

### 总结

您不能直接通过 NAN 协议发送长文本。您必须：

1.  使用 NAN（Wi-Fi Aware）进行**设备发现**。
2.  使用 `NetworkRequest` 和 `WifiAwareNetworkSpecifier` 来**建立数据路径**。
3.  通过建立的 `Socket` 连接来**传输您的长文本**或任何其他大数据。