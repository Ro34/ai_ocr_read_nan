package com.example.ai_ocr_read

import android.content.Context
import android.net.*
import android.net.wifi.aware.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.*
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Wi-Fi Aware Data Path 管理器
 * 负责建立和管理 Wi-Fi Aware 数据路径连接，用于传输大数据（如长文本）
 */
@RequiresApi(Build.VERSION_CODES.Q)
class DataPathManager(private val context: Context) {
    private val tag = "DataPathManager"
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    // Peer 管理：Flutter 侧使用的 peerId -> PeerHandle 映射
    private val peerIdSeq = AtomicInteger(1)
    private val peers = ConcurrentHashMap<Int, PeerInfo>()
    
    // 数据路径连接管理
    private val dataSockets = ConcurrentHashMap<Int, Socket>()
    private val dataWriters = ConcurrentHashMap<Int, DataOutputStream>()
    private val dataReaderJobs = ConcurrentHashMap<Int, Job>()
    private val networkCallbacks = ConcurrentHashMap<Int, ConnectivityManager.NetworkCallback>()
    
    // 连接建立同步锁 - 防止双向连接竞争
    private val connectionLocks = ConcurrentHashMap<Int, Any>()
    
    // 服务端监听（作为 responder 角色）
    private var serverSocket: ServerSocket? = null
    private var serverJob: Job? = null
    private var isResponder = false
    
    private var eventSink: EventChannel.EventSink? = null

    data class PeerInfo(
        val peerId: Int,
        val peerHandle: PeerHandle,
        val deviceId: String?,
        val discoverySession: DiscoverySession,
        var publishSession: PublishDiscoverySession? = null,
        var passphrase: String? = null,
        var port: Int = 0
    )

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    private fun emit(event: Map<String, Any?>) {
        handler.post {
            try {
                eventSink?.success(event)
            } catch (_: Throwable) {
                // ignore
            }
        }
    }

    /**
     * 注册一个已发现的 peer，返回 peerId 供 Flutter 使用
     */
    fun registerPeer(peerHandle: PeerHandle, deviceId: String?, session: DiscoverySession): Int {
        // 优先检查 deviceId 是否已注册(同一设备可能有多个 peerHandle)
        if (deviceId != null && deviceId.isNotEmpty()) {
            peers.values.forEach { info ->
                if (info.deviceId == deviceId) {
                    Log.d(tag, "Peer with deviceId=$deviceId already registered as peerId=${info.peerId}")
                    return info.peerId
                }
                // 也检查提取后的 ID 是否匹配(处理 "dev-xxx-yyy" 格式)
                val existingIdExtracted = if (info.deviceId?.startsWith("dev-") == true) {
                    info.deviceId!!.substringAfter("dev-").substringBefore("-")
                } else {
                    info.deviceId
                }
                val newIdExtracted = if (deviceId.startsWith("dev-")) {
                    deviceId.substringAfter("dev-").substringBefore("-")
                } else {
                    deviceId
                }
                if (existingIdExtracted == newIdExtracted && existingIdExtracted != null) {
                    Log.d(tag, "Peer with extracted deviceId=$newIdExtracted already registered as peerId=${info.peerId}, updating to $deviceId")
                    // 更新为更精确的 deviceId(优先使用纯 ANDROID_ID)
                    if (!deviceId.startsWith("dev-") && info.deviceId?.startsWith("dev-") == true) {
                        peers[info.peerId] = info.copy(deviceId = deviceId)
                        Log.d(tag, "Updated deviceId from ${info.deviceId} to $deviceId")
                    }
                    return info.peerId
                }
            }
        }
        
        // 检查是否已通过 peerHandle 注册
        peers.values.forEach { info ->
            if (info.peerHandle == peerHandle) {
                // 如果有新的 deviceId,更新它
                if (deviceId != null && deviceId.isNotEmpty() && info.deviceId != deviceId) {
                    Log.d(tag, "Updating deviceId for peerId=${info.peerId} from ${info.deviceId} to $deviceId")
                    peers[info.peerId] = info.copy(deviceId = deviceId)
                }
                return info.peerId
            }
        }
        
        val peerId = peerIdSeq.getAndIncrement()
        val info = PeerInfo(peerId, peerHandle, deviceId, session)
        peers[peerId] = info
        
        Log.d(tag, "Registered peer $peerId (deviceId=$deviceId)")
        emit(mapOf(
            "type" to "peerRegistered",
            "peerId" to peerId,
            "deviceId" to deviceId
        ))
        
        return peerId
    }

    /**
     * 获取所有已注册的 peer 列表
     */
    fun listPeers(): List<Map<String, Any?>> {
        return peers.values.map { info ->
            mapOf(
                "peerId" to info.peerId,
                "deviceId" to info.deviceId,
                "hasDataPath" to dataSockets.containsKey(info.peerId)
            )
        }
    }

    /**
     * 作为发起方（initiator）建立数据路径到指定 peer
     */
    fun openDataPath(
        peerId: Int,
        passphrase: String?,
        port: Int = 0,
        onSuccess: (() -> Unit)? = null,
        onError: ((String) -> Unit)? = null
    ) {
        val peerInfo = peers[peerId]
        if (peerInfo == null) {
            Log.e(tag, "Peer $peerId not found")
            onError?.invoke("Peer not found")
            return
        }

        // 检查是否已经存在连接或正在连接
        if (dataSockets.containsKey(peerId)) {
            Log.w(tag, "Data path for peer $peerId already established")
            onSuccess?.invoke()
            return
        }
        
        if (networkCallbacks.containsKey(peerId)) {
            Log.w(tag, "Data path for peer $peerId is already being established, skipping")
            onSuccess?.invoke()
            return
        }

        // 保存 passphrase 和 port 到 PeerInfo
        peerInfo.passphrase = passphrase
        peerInfo.port = if (port > 0) port else 8888
        
        // 如果 discoverySession 是 PublishDiscoverySession，保存它
        if (peerInfo.discoverySession is PublishDiscoverySession) {
            peerInfo.publishSession = peerInfo.discoverySession as PublishDiscoverySession
        }

        Log.d(tag, "Opening data path to peer $peerId as initiator (role determined by session type)")
        Log.d(tag, "Passphrase: ${if (passphrase.isNullOrEmpty()) "null/empty" else "***"}, Port: ${peerInfo.port}")
        
        // 发送协商请求消息（通知对端准备建立连接）
        sendNegotiationRequest(peerInfo)
        
        // 后续的 requestNetwork 会在 continueOpenDataPath 中执行
        // （给对端时间响应 ACK）
    }

    /**
     * 作为响应方（responder）监听数据路径连接
     * 注意：此方法需要在发现服务时就开始监听
     */
    fun startResponderMode(
        session: DiscoverySession,
        peerHandle: PeerHandle,
        passphrase: String?,
        port: Int = 0,
        onSuccess: (() -> Unit)? = null,
        onError: ((String) -> Unit)? = null
    ) {
        if (isResponder) {
            Log.w(tag, "Already in responder mode")
            onSuccess?.invoke()
            return
        }

        Log.d(tag, "Starting responder mode")
        isResponder = true
        
        // 构建 NetworkSpecifier
        val builder = WifiAwareNetworkSpecifier.Builder(session, peerHandle)
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && port > 0) {
            builder.setPort(port)
        }
        
        if (!passphrase.isNullOrBlank()) {
            try {
                builder.setPskPassphrase(passphrase)
            } catch (e: Exception) {
                Log.w(tag, "Failed to set passphrase: ${e.message}")
            }
        }
        
        val networkSpecifier = builder.build()
        
        val networkRequest = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(networkSpecifier)
            .build()
        
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.d(tag, "Responder: Network available")
                
                scope.launch {
                    try {
                        // 作为服务端监听连接
                        serverSocket = ServerSocket()
                        val localPort = if (port > 0) port else 0 // 0 表示随机端口
                        serverSocket?.bind(InetSocketAddress(localPort))
                        
                        val boundPort = serverSocket?.localPort ?: 0
                        Log.d(tag, "Server socket listening on port $boundPort")
                        
                        emit(mapOf(
                            "type" to "responder",
                            "state" to "listening",
                            "port" to boundPort
                        ))
                        
                        // 接受连接
                        serverJob = launch {
                            while (isActive) {
                                try {
                                    val clientSocket = serverSocket?.accept()
                                    if (clientSocket != null) {
                                        Log.d(tag, "Accepted connection from peer")
                                        handleIncomingConnection(clientSocket)
                                    }
                                } catch (e: Exception) {
                                    if (isActive) {
                                        Log.e(tag, "Error accepting connection: ${e.message}", e)
                                    }
                                    break
                                }
                            }
                        }
                        
                        onSuccess?.invoke()
                        
                    } catch (e: Exception) {
                        Log.e(tag, "Failed to start server socket: ${e.message}", e)
                        emit(mapOf(
                            "type" to "responder",
                            "state" to "error",
                            "error" to (e.message ?: "Server socket failed")
                        ))
                        onError?.invoke(e.message ?: "Server socket failed")
                    }
                }
            }

            override fun onUnavailable() {
                Log.w(tag, "Responder: Network unavailable")
                emit(mapOf("type" to "responder", "state" to "unavailable"))
                onError?.invoke("Network unavailable")
            }

            override fun onLost(network: Network) {
                Log.w(tag, "Responder: Network lost")
                stopResponderMode()
                emit(mapOf("type" to "responder", "state" to "lost"))
            }
        }
        
        connectivityManager.requestNetwork(networkRequest, callback)
    }

    private fun handleIncomingConnection(socket: Socket) {
        scope.launch {
            try {
                // 为这个连接分配一个临时 peerId
                val peerId = peerIdSeq.getAndIncrement()
                
                dataSockets[peerId] = socket
                val outputStream = DataOutputStream(socket.getOutputStream())
                dataWriters[peerId] = outputStream
                
                // 立即发送握手消息
                try {
                    val handshake = "HELLO".toByteArray(Charsets.UTF_8)
                    outputStream.writeInt(handshake.size)
                    outputStream.write(handshake)
                    outputStream.flush()
                    Log.d(tag, "Server sent handshake to peer $peerId")
                } catch (e: Exception) {
                    Log.w(tag, "Server failed to send handshake: ${e.message}")
                }
                
                emit(mapOf(
                    "type" to "dataPath",
                    "state" to "available",
                    "peerId" to peerId,
                    "role" to "responder"
                ))
                
                startReadingLoop(peerId, socket)
                
            } catch (e: Exception) {
                Log.e(tag, "Error handling incoming connection: ${e.message}", e)
                try { socket.close() } catch (_: Exception) {}
            }
        }
    }

    private fun startReadingLoop(peerId: Int, socket: Socket) {
        val job = scope.launch {
            try {
                val inputStream = DataInputStream(socket.getInputStream())
                
                while (isActive && !socket.isClosed) {
                    try {
                        // 读取 4 字节长度前缀（网络字节序，大端）
                        val lengthBytes = ByteArray(4)
                        inputStream.readFully(lengthBytes)
                        val length = ByteBuffer.wrap(lengthBytes).int
                        
                        // 安全检查：防止恶意的超大长度
                        if (length < 0 || length > 10 * 1024 * 1024) { // 最大 10MB
                            Log.w(tag, "Received invalid length: $length, closing connection")
                            break
                        }
                        
                        // 读取实际数据
                        val dataBytes = ByteArray(length)
                        inputStream.readFully(dataBytes)
                        
                        val text = String(dataBytes, Charsets.UTF_8)
                        
                        // 检查是否是握手消息
                        if (text == "HELLO") {
                            Log.d(tag, "Received handshake from peer $peerId")
                            continue // 跳过握手消息,不通知上层
                        }
                        
                        Log.d(tag, "Received ${dataBytes.size} bytes from peer $peerId")
                        
                        emit(mapOf(
                            "type" to "dataMessage",
                            "peerId" to peerId,
                            "text" to text,
                            "bytes" to dataBytes.size
                        ))
                        
                    } catch (e: Exception) {
                        if (isActive && !socket.isClosed) {
                            Log.e(tag, "Error reading from peer $peerId: ${e.message}")
                        }
                        break
                    }
                }
                
            } catch (e: Exception) {
                Log.e(tag, "Reading loop error for peer $peerId: ${e.message}")
            } finally {
                closeDataPath(peerId)
            }
        }
        
        dataReaderJobs[peerId] = job
    }

    /**
     * 通过数据路径发送长文本
     */
    fun sendLargeText(
        peerId: Int,
        text: String,
        onSuccess: (() -> Unit)? = null,
        onError: ((String) -> Unit)? = null
    ) {
        val writer = dataWriters[peerId]
        if (writer == null) {
            val msg = "Data path not established for peer $peerId"
            Log.e(tag, msg)
            onError?.invoke(msg)
            return
        }
        
        scope.launch {
            try {
                val dataBytes = text.toByteArray(Charsets.UTF_8)
                val lengthBytes = ByteBuffer.allocate(4).putInt(dataBytes.size).array()
                
                // 发送长度前缀 + 数据
                synchronized(writer) {
                    writer.write(lengthBytes)
                    writer.write(dataBytes)
                    writer.flush()
                }
                
                Log.d(tag, "Sent ${dataBytes.size} bytes to peer $peerId")
                
                emit(mapOf(
                    "type" to "dataSent",
                    "peerId" to peerId,
                    "bytes" to dataBytes.size
                ))
                
                onSuccess?.invoke()
                
            } catch (e: Exception) {
                Log.e(tag, "Failed to send data to peer $peerId: ${e.message}", e)
                emit(mapOf(
                    "type" to "dataSendError",
                    "peerId" to peerId,
                    "error" to (e.message ?: "Send failed")
                ))
                onError?.invoke(e.message ?: "Send failed")
            }
        }
    }

    /**
     * 关闭指定 peer 的数据路径
     */
    fun closeDataPath(peerId: Int) {
        Log.d(tag, "Closing data path for peer $peerId")
        
        dataReaderJobs.remove(peerId)?.cancel()
        
        try {
            dataWriters.remove(peerId)?.close()
        } catch (e: Exception) {
            Log.w(tag, "Error closing writer for peer $peerId: ${e.message}")
        }
        
        try {
            dataSockets.remove(peerId)?.close()
        } catch (e: Exception) {
            Log.w(tag, "Error closing socket for peer $peerId: ${e.message}")
        }
        
        networkCallbacks.remove(peerId)?.let { callback ->
            try {
                val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                cm.unregisterNetworkCallback(callback)
            } catch (e: Exception) {
                Log.w(tag, "Error unregistering network callback: ${e.message}")
            }
        }
        
        emit(mapOf(
            "type" to "dataPath",
            "state" to "closed",
            "peerId" to peerId
        ))
    }

    /**
     * 停止 responder 模式
     */
    fun stopResponderMode() {
        if (!isResponder) return
        
        Log.d(tag, "Stopping responder mode")
        isResponder = false
        
        serverJob?.cancel()
        serverJob = null
        
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            Log.w(tag, "Error closing server socket: ${e.message}")
        }
        serverSocket = null
        
        emit(mapOf("type" to "responder", "state" to "stopped"))
    }

    /**
     * 发送协商请求消息到对端
     */
    private fun sendNegotiationRequest(peerInfo: PeerInfo) {
        val deviceId = android.provider.Settings.Secure.getString(
            context.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID
        ) ?: "unknown"
        val message = "DATA_PATH_REQUEST:$deviceId"
        
        try {
            Log.i(tag, "!!! Sending negotiation request to peer ${peerInfo.peerId} !!!")
            Log.i(tag, "Message: [$message]")
            Log.i(tag, "DeviceId: $deviceId")
            
            // 根据 discoverySession 的类型来发送消息
            when (val session = peerInfo.discoverySession) {
                is PublishDiscoverySession -> {
                    Log.i(tag, "Using PublishDiscoverySession to send")
                    session.sendMessage(peerInfo.peerHandle, 0, message.toByteArray())
                }
                is SubscribeDiscoverySession -> {
                    Log.i(tag, "Using SubscribeDiscoverySession to send")
                    session.sendMessage(peerInfo.peerHandle, 0, message.toByteArray())
                }
                else -> {
                    Log.e(tag, "!!! ERROR: Unknown discovery session type !!!")
                }
            }
            Log.i(tag, "Negotiation request sent successfully")
        } catch (e: Exception) {
            Log.e(tag, "!!! ERROR: Failed to send negotiation request: ${e.message} !!!", e)
        }
        
        // 极短延迟后建立连接，确保与对端的时间窗口重叠
        // 对端在收到消息后 200ms + 1700ms = 1900ms 开始 requestNetwork
        // 我们在 2000ms 开始 requestNetwork，时间窗口重叠
        handler.postDelayed({
            continueOpenDataPath(peerInfo)
        }, 2000)
    }
    
    /**
     * 继续建立数据路径（在发送协商请求后）
     */
    private fun continueOpenDataPath(peerInfo: PeerInfo) {
        val peerId = peerInfo.peerId
        Log.d(tag, "Continuing to establish data path for peer $peerId")
        
        // 如果已经建立了连接（对端快速响应），就不重复建立
        if (dataSockets.containsKey(peerId)) {
            Log.d(tag, "Data path already established for peer $peerId")
            return
        }
        
        // 继续原来的 requestNetwork 流程
        executeNetworkRequest(peerInfo)
    }
    
    /**
     * 执行实际的网络请求（从 openDataPath 中提取出来）
     */
    private fun executeNetworkRequest(peerInfo: PeerInfo) {
        val peerId = peerInfo.peerId
        
        // 检查是否已经有 callback 正在处理
        if (networkCallbacks.containsKey(peerId)) {
            Log.w(tag, "Network callback already exists for peer $peerId, skipping duplicate request")
            return
        }
        
        val builder = WifiAwareNetworkSpecifier.Builder(
            peerInfo.discoverySession,
            peerInfo.peerHandle
        )
        
        // 使用局部变量避免 Kotlin 智能转换问题
        val passphrase = peerInfo.passphrase
        if (!passphrase.isNullOrBlank()) {
            try {
                builder.setPskPassphrase(passphrase)
                Log.d(tag, "Using passphrase for data path (length=${passphrase.length})")
                
                // 重要：端口只能在secure link(有passphrase)时设置
                // 且只有 PublishDiscoverySession（发布方/服务端）才能设置端口
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && 
                    peerInfo.port > 0 && 
                    peerInfo.discoverySession is PublishDiscoverySession) {
                    try {
                        builder.setPort(peerInfo.port)
                        Log.d(tag, "Set port ${peerInfo.port} (as Publisher/Server)")
                    } catch (e: Exception) {
                        Log.w(tag, "Failed to set port: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                Log.e(tag, "Failed to set passphrase: ${e.message}", e)
                emit(mapOf(
                    "type" to "dataPath",
                    "state" to "failed",
                    "peerId" to peerId,
                    "error" to "Passphrase error: ${e.message}"
                ))
                return
            }
        } else {
            Log.w(tag, "No passphrase provided for peer $peerId - using open mode without port")
        }
        
        val networkSpecifier = builder.build()
        
        val networkRequest = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(networkSpecifier)
            .build()
        
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.d(tag, "Network available for peer $peerId")
                
                try {
                    connectivityManager.bindProcessToNetwork(network)
                    
                    val linkProperties = connectivityManager.getLinkProperties(network)
                    
                    // 获取本地IPv6地址(用于绑定)
                    val localIpv6Address = linkProperties?.linkAddresses
                        ?.firstOrNull { it.address is java.net.Inet6Address }
                        ?.address
                    
                    // 获取对端IPv6地址(用于连接)
                    val networkCapabilities = connectivityManager.getNetworkCapabilities(network)
                    val transportInfo = networkCapabilities?.transportInfo
                    val peerIpv6Address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && 
                                              transportInfo is android.net.wifi.aware.WifiAwareNetworkInfo) {
                        transportInfo.peerIpv6Addr
                    } else {
                        null
                    }
                    
                    if (localIpv6Address == null) {
                        Log.e(tag, "No local IPv6 address found for peer $peerId")
                        emit(mapOf(
                            "type" to "dataPath",
                            "state" to "failed",
                            "peerId" to peerId,
                            "error" to "No local IPv6 address"
                        ))
                        return
                    }
                    
                    Log.d(tag, "Local IPv6 address: $localIpv6Address")
                    if (peerIpv6Address != null) {
                        Log.d(tag, "Peer IPv6 address: $peerIpv6Address")
                    } else {
                        Log.w(tag, "Could not get peer IPv6 address from WifiAwareNetworkInfo")
                    }
                    
                    // 决定角色策略: 比较设备 ID,避免双向连接竞争
                    // 设备 ID 较小的作为 Server 监听,较大的作为 Client 连接
                    val localDeviceId = android.provider.Settings.Secure.getString(
                        context.contentResolver,
                        android.provider.Settings.Secure.ANDROID_ID
                    ) ?: "unknown"
                    
                    // 提取纯设备 ID(移除 "dev-" 前缀和后缀)
                    // 格式: dev-{androidId}-{randomSuffix} -> 提取 androidId 部分
                    val remoteDeviceIdRaw = peerInfo.deviceId ?: ""
                    val remoteDeviceId = if (remoteDeviceIdRaw.startsWith("dev-")) {
                        // 提取第一个"-"和第二个"-"之间的部分
                        remoteDeviceIdRaw.substringAfter("dev-").substringBefore("-")
                    } else {
                        remoteDeviceIdRaw
                    }
                    
                    if (remoteDeviceId.isEmpty()) {
                        Log.e(tag, "Remote device ID is empty! Cannot determine role. Raw: $remoteDeviceIdRaw")
                        emit(mapOf(
                            "type" to "dataPath",
                            "state" to "failed",
                            "peerId" to peerId,
                            "error" to "Remote device ID unknown"
                        ))
                        return
                    }
                    
                    val shouldBeServer = localDeviceId < remoteDeviceId
                    Log.d(tag, "Role decision for peer $peerId: localId=$localDeviceId, remoteId=$remoteDeviceId (raw=$remoteDeviceIdRaw), shouldBeServer=$shouldBeServer")
                    
                    if (shouldBeServer) {
                        // 作为 Server 监听
                        Log.d(tag, "Acting as SERVER for peer $peerId")
                        scope.launch {
                            try {
                                val serverSock = withContext(Dispatchers.IO) {
                                    // ServerSocket 绑定到本地IPv6地址
                                    val ss = ServerSocket()
                                    val bindAddr = InetSocketAddress(localIpv6Address, peerInfo.port.takeIf { it > 0 } ?: 8888)
                                    Log.d(tag, "Binding ServerSocket to $localIpv6Address:${peerInfo.port.takeIf { it > 0 } ?: 8888}")
                                    ss.bind(bindAddr)
                                    ss
                                }
                                Log.d(tag, "Listening on port ${serverSock.localPort} for peer $peerId")
                                
                                val accepted = withContext(Dispatchers.IO) {
                                    serverSock.accept()
                                }
                                
                                Log.d(tag, "Accepted connection from peer $peerId")
                                
                                // 立即发送握手消息
                                try {
                                    val outputStream = DataOutputStream(accepted.getOutputStream())
                                    dataWriters[peerId] = outputStream
                                    val handshake = "HELLO".toByteArray(Charsets.UTF_8)
                                    outputStream.writeInt(handshake.size)
                                    outputStream.write(handshake)
                                    outputStream.flush()
                                    Log.d(tag, "Server sent handshake to peer $peerId")
                                } catch (e: Exception) {
                                    Log.w(tag, "Server failed to send handshake: ${e.message}")
                                    accepted.close()
                                    serverSock.close()
                                    emit(mapOf(
                                        "type" to "dataPath",
                                        "state" to "failed",
                                        "peerId" to peerId,
                                        "error" to "Handshake failed: ${e.message}"
                                    ))
                                    return@launch
                                }
                                
                                dataSockets[peerId] = accepted
                                Log.d(tag, "Data path established (as server) for peer $peerId")
                                
                                emit(mapOf(
                                    "type" to "dataPath",
                                    "state" to "available",
                                    "peerId" to peerId,
                                    "role" to "server"
                                ))
                                
                                startReadingLoop(peerId, accepted)
                                serverSock.close()
                                
                            } catch (e: Exception) {
                                Log.e(tag, "Server socket error for peer $peerId: ${e.message}", e)
                                emit(mapOf(
                                    "type" to "dataPath",
                                    "state" to "failed",
                                    "peerId" to peerId,
                                    "error" to "Server error: ${e.message}"
                                ))
                            }
                        }
                    } else {
                        // 作为 Client 连接
                        Log.d(tag, "Acting as CLIENT for peer $peerId")
                        
                        // 检查是否有对端地址
                        if (peerIpv6Address == null) {
                            Log.e(tag, "Cannot connect: peer IPv6 address is null")
                            emit(mapOf(
                                "type" to "dataPath",
                                "state" to "failed",
                                "peerId" to peerId,
                                "error" to "No peer IPv6 address"
                            ))
                            return
                        }
                        
                        scope.launch {
                            delay(200) // 给 server 端时间启动
                            try {
                                val socket = withContext(Dispatchers.IO) {
                                    // 关键修复: 创建 Socket 并绑定到 Wi-Fi Aware 网络
                                    // 必须在连接前绑定,否则 IPv6 link-local 连接会失败 (EINVAL)
                                    val s = Socket()
                                    
                                    // 先绑定到本地地址(强制使用 Wi-Fi Aware 网络)
                                    Log.d(tag, "Binding socket to local address: $localIpv6Address")
                                    s.bind(InetSocketAddress(localIpv6Address, 0)) // 0 = 随机本地端口
                                    
                                    Log.d(tag, "Connecting to peer $peerIpv6Address:8888...")
                                    s.connect(
                                        InetSocketAddress(peerIpv6Address, peerInfo.port.takeIf { it > 0 } ?: 8888),
                                        10000 // 增加超时到 10 秒
                                    )
                                    s
                                }
                                
                                dataSockets[peerId] = socket
                                Log.d(tag, "Data path established (as client) for peer $peerId")
                                
                                // 立即发送握手消息,让对端的读取循环不会阻塞
                                try {
                                    val outputStream = DataOutputStream(socket.getOutputStream())
                                    dataWriters[peerId] = outputStream
                                    val handshake = "HELLO".toByteArray(Charsets.UTF_8)
                                    outputStream.writeInt(handshake.size)
                                    outputStream.write(handshake)
                                    outputStream.flush()
                                    Log.d(tag, "Client sent handshake to peer $peerId")
                                } catch (e: Exception) {
                                    Log.w(tag, "Client failed to send handshake: ${e.message}")
                                    socket.close()
                                    dataSockets.remove(peerId)
                                    emit(mapOf(
                                        "type" to "dataPath",
                                        "state" to "failed",
                                        "peerId" to peerId,
                                        "error" to "Handshake failed: ${e.message}"
                                    ))
                                    return@launch
                                }
                                
                                emit(mapOf(
                                    "type" to "dataPath",
                                    "state" to "available",
                                    "peerId" to peerId,
                                    "role" to "client"
                                ))
                                
                                startReadingLoop(peerId, socket)
                                
                            } catch (e: Exception) {
                                Log.e(tag, "Client connect error for peer $peerId: ${e.message}", e)
                                emit(mapOf(
                                    "type" to "dataPath",
                                    "state" to "failed",
                                    "peerId" to peerId,
                                    "error" to "Client error: ${e.message}"
                                ))
                            }
                        }
                    }
                    
                } catch (e: Exception) {
                    Log.e(tag, "Error in onAvailable for peer $peerId: ${e.message}", e)
                    emit(mapOf(
                        "type" to "dataPath",
                        "state" to "failed",
                        "peerId" to peerId,
                        "error" to e.message
                    ))
                }
            }
            
            override fun onUnavailable() {
                Log.w(tag, "Network unavailable for peer $peerId")
                emit(mapOf(
                    "type" to "dataPath",
                    "state" to "unavailable",
                    "peerId" to peerId
                ))
                networkCallbacks.remove(peerId)
            }
            
            override fun onLost(network: Network) {
                Log.w(tag, "Data path lost for peer $peerId")
                closeDataPath(peerId)
                emit(mapOf(
                    "type" to "dataPath",
                    "state" to "lost",
                    "peerId" to peerId
                ))
                networkCallbacks.remove(peerId)
            }
            
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                Log.d(tag, "Network capabilities changed for peer $peerId")
            }
        }
        
        networkCallbacks[peerId] = callback
        connectivityManager.requestNetwork(networkRequest, callback)
    }

    /**
     * 关闭所有数据路径并清理资源
     */
    fun releaseAll() {
        Log.d(tag, "Releasing all data paths")
        
        stopResponderMode()
        
        val peerIds = dataSockets.keys.toList()
        peerIds.forEach { closeDataPath(it) }
        
        peers.clear()
        
        scope.cancel()
        
        emit(mapOf("type" to "dataPathManager", "state" to "released"))
    }
}
