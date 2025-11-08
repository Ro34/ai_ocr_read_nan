package com.example.ai_ocr_read

import android.content.Context
import android.location.LocationManager
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.provider.Settings
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.EventChannel
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicInteger

@RequiresApi(Build.VERSION_CODES.O)
class NanManager(private val context: Context) {
    private val tag = "NanManager"
    private val handler = Handler(Looper.getMainLooper())

    private val aware: WifiAwareManager? = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
    private var session: WifiAwareSession? = null
    private var pub: PublishDiscoverySession? = null
    private var sub: SubscribeDiscoverySession? = null
    
    // 数据路径管理器（API 29+）
    private var dataPathManager: DataPathManager? = null
    
    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dataPathManager = DataPathManager(context)
        }
    }
    // 区分不同会话来源的 peer handle，便于使用正确的会话发送消息
    private val subPeers = mutableSetOf<PeerHandle>()
    private val pubPeers = mutableSetOf<PeerHandle>()
    // 基于对端的自带 deviceId 去重（从 SSI 或消息信封解析），映射到最新的 handle
    private val peerIds = mutableSetOf<String>()
    private val subIdToPeer = mutableMapOf<String, PeerHandle>()
    private val pubIdToPeer = mutableMapOf<String, PeerHandle>()
    // 记录已握手过的设备，避免重复发送握手消息
    private val handshakedIds = mutableSetOf<String>()
    // 记录已处理的 DATA_PATH_REQUEST，避免重复响应导致死循环
    private val processedDataPathRequests = mutableSetOf<String>()
    private val msgId = AtomicInteger(1)
    private var eventSink: EventChannel.EventSink? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dataPathManager?.setEventSink(sink)
        }
    }

    private fun emit(event: Map<String, Any?>) {
        try {
            eventSink?.success(event)
        } catch (_: Throwable) {
            // ignore
        }
    }

    fun isAvailable(): Boolean {
        val a = aware ?: return false
        return a.isAvailable
    }

    fun isLocationEnabled(): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm.isLocationEnabled
        } else {
            try {
                val mode = Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE, Settings.Secure.LOCATION_MODE_OFF)
                mode != Settings.Secure.LOCATION_MODE_OFF
            } catch (_: Throwable) {
                false
            }
        }
    }

    /**
     * 返回设备支持的 sendMessage 最大字节数。如果系统未提供公开 API，则通过反射尝试；
     * 若仍不可得，返回一个保守的回退值。
     */
    fun getMaxMessageLength(): Int {
        val a = aware ?: return 0
        return try {
            val ch = a.javaClass.getMethod("getCharacteristics").invoke(a)
            // 优先尝试 getMaxMessageLength（较新的 API）
            val m1 = ch.javaClass.methods.firstOrNull { it.name == "getMaxMessageLength" }
            if (m1 != null) {
                (m1.invoke(ch) as? Int) ?: 0
            } else {
                // 一些系统方法名可能不同，兼容 getMaxSendMessageLength
                val m2 = ch.javaClass.methods.firstOrNull { it.name == "getMaxSendMessageLength" }
                if (m2 != null) (m2.invoke(ch) as? Int) ?: 0 else 0
            }
        } catch (_: Throwable) {
            0
        }.let { if (it > 0) it else 1800 } // 回退一个保守值
    }

    fun attach(onSuccess: (() -> Unit)? = null, onError: ((String) -> Unit)? = null) {
        val a = aware ?: run {
            onError?.invoke("WifiAware not supported")
            return
        }
        // 已有 session 则直接回调成功，避免重复 attach 造成多会话
        val existing = session
        if (existing != null) {
            emit(mapOf("type" to "attached"))
            onSuccess?.invoke()
            return
        }
        a.attach(object : AttachCallback() {
            override fun onAttached(sess: WifiAwareSession) {
                Log.d(tag, "attach success")
                session = sess
                emit(mapOf("type" to "attached"))
                // 连接成功后主动上报设备可发送的最大消息长度，便于 Flutter 侧记录
                try {
                    val max = getMaxMessageLength()
                    Log.d(tag, "maxMessageLen=$max")
                    emit(mapOf("type" to "maxMessageLen", "max" to max))
                } catch (_: Throwable) {}
                onSuccess?.invoke()
            }

            override fun onAttachFailed() {
                Log.e(tag, "attach failed")
                onError?.invoke("attach failed")
            }
        }, handler)
    }

    fun startPublish(serviceName: String, ssi: String? = null, broadcast: Boolean = true) {
        val s = session ?: return
        if (pub != null) {
            // 已经在发布，避免重复
            emit(mapOf("type" to "publish", "state" to "started"))
            return
        }
        val cfg = PublishConfig.Builder()
            .setServiceName(serviceName)
            .setPublishType(if (broadcast) PublishConfig.PUBLISH_TYPE_UNSOLICITED else PublishConfig.PUBLISH_TYPE_SOLICITED)
            .apply {
                ssi?.let { setServiceSpecificInfo(it.toByteArray(StandardCharsets.UTF_8)) }
                // 从 ssi 中解析 room 参数设置 matchFilter，限制只有相同房间能匹配
                val room = parseRoomFromSsi(ssi)
                if (!room.isNullOrEmpty()) {
                    setMatchFilter(listOf(room.toByteArray(StandardCharsets.UTF_8)))
                }
            }
            .build()
        s.publish(cfg, object : DiscoverySessionCallback() {
            override fun onPublishStarted(ps: PublishDiscoverySession) {
                Log.d(tag, "publish started")
                pub = ps
                emit(mapOf("type" to "publish", "state" to "started"))
            }

            override fun onMessageSendSucceeded(messageId: Int) {
                Log.d(tag, "publish send ok id=$messageId")
                emit(mapOf("type" to "send", "via" to "publish", "result" to "ok", "id" to messageId))
            }

            override fun onMessageSendFailed(messageId: Int) {
                Log.w(tag, "publish send fail id=$messageId")
                emit(mapOf("type" to "send", "via" to "publish", "result" to "fail", "id" to messageId))
            }

            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                val text = try { String(message, StandardCharsets.UTF_8) } catch (_: Throwable) { "<bin>" }
                Log.i(tag, "!!! PUBLISH onMessageReceived called !!!")
                Log.i(tag, "Message content: [$text]")
                Log.i(tag, "PeerHandle: ${peerHandle.hashCode()}")
                if (!pubPeers.contains(peerHandle)) pubPeers.add(peerHandle)
                
                // 检查是否是数据路径协商消息 (与 Subscribe 相同的逻辑)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    Log.i(tag, "Checking if message is DATA_PATH_REQUEST...")
                    if (text.startsWith("DATA_PATH_REQUEST:")) {
                        Log.i(tag, "!!! DATA_PATH_REQUEST detected in PUBLISH !!!")
                        // 收到数据路径请求，自动响应
                        val parts = text.split(":")
                        if (parts.size >= 2) {
                            val requesterDevId = parts[1]
                            Log.i(tag, "!!! Parsed requester deviceId: $requesterDevId !!!")
                            
                            // 检查是否已经处理过此设备的请求
                            if (processedDataPathRequests.contains(requesterDevId)) {
                                Log.i(tag, "Already processed DATA_PATH_REQUEST from $requesterDevId, ignoring")
                                return // 已处理，避免重复响应
                            }
                            processedDataPathRequests.add(requesterDevId)
                            
                            // 找到对应的 peerId
                            val session = pub
                            Log.i(tag, "Publish session exists: ${session != null}")
                            if (session != null) {
                                Log.i(tag, "Calling DataPathManager.registerPeer...")
                                val peerId = dataPathManager?.registerPeer(peerHandle, requesterDevId, session)
                                Log.i(tag, "registerPeer returned: $peerId")
                                if (peerId != null) {
                                    Log.i(tag, "!!! Auto-responding to DATA_PATH_REQUEST, peerId=$peerId !!!")
                                    
                                    // 发送 ACK
                                    try {
                                        val ackMsg = "DATA_PATH_ACK"
                                        val ackData = ackMsg.toByteArray(StandardCharsets.UTF_8)
                                        val ackId = msgId.getAndIncrement()
                                        pub?.sendMessage(peerHandle, ackId, ackData)
                                    } catch (_: Throwable) {}
                                    
                                    // 延迟后调用 openDataPath (使用固定passphrase)
                                    Log.i(tag, "Scheduling openDataPath for peer $peerId after 200ms delay...")
                                    handler.postDelayed({
                                        Log.i(tag, "!!! Executing delayed openDataPath for peer $peerId !!!")
                                        dataPathManager?.openDataPath(
                                            peerId = peerId,
                                            passphrase = "aiocr_data_path_2024", // 固定passphrase
                                            onSuccess = {
                                                Log.i(tag, "!!! SUCCESS: Auto data path established for peer $peerId !!!")
                                            },
                                            onError = { err ->
                                                Log.e(tag, "!!! ERROR: Auto data path failed for peer $peerId: $err !!!")
                                            }
                                        )
                                    }, 200) // 极短延迟，快速响应
                                }
                            }
                        }
                        return // 已处理，不再继续
                    }
                }
                
                // 尝试解析消息信封中的 sender 以去重与映射
                try {
                    val json = org.json.JSONObject(text)
                    val sender = json.optString("sender", "")
                    if (sender.isNotEmpty()) {
                        peerIds.add(sender)
                        pubIdToPeer[sender] = peerHandle
                        emit(mapOf("type" to "discovered", "peers" to peerIds.size))
                    }
                } catch (_: Throwable) {}
                emit(mapOf("type" to "message", "via" to "publish", "text" to text))
            }

            override fun onSessionTerminated() {
                Log.d(tag, "publish terminated")
                pub = null
                emit(mapOf("type" to "publish", "state" to "terminated"))
            }
        }, handler)
    }

    fun startSubscribe(serviceName: String, ssi: String? = null) {
        val s = session ?: return
        if (sub != null) {
            // 已经在订阅，避免重复
            emit(mapOf("type" to "subscribe", "state" to "started"))
            return
        }
        val cfg = SubscribeConfig.Builder()
            .setServiceName(serviceName)
            .apply {
                ssi?.let { setServiceSpecificInfo(it.toByteArray(StandardCharsets.UTF_8)) }
                val room = parseRoomFromSsi(ssi)
                if (!room.isNullOrEmpty()) {
                    setMatchFilter(listOf(room.toByteArray(StandardCharsets.UTF_8)))
                }
            }
            .build()
        s.subscribe(cfg, object : DiscoverySessionCallback() {
            override fun onSubscribeStarted(ss: SubscribeDiscoverySession) {
                Log.d(tag, "subscribe started")
                sub = ss
                emit(mapOf("type" to "subscribe", "state" to "started"))
            }

            override fun onServiceDiscovered(peerHandle: PeerHandle, serviceSpecificInfo: ByteArray?, matchFilter: MutableList<ByteArray>?) {
                if (!subPeers.contains(peerHandle)) subPeers.add(peerHandle)
                var devId: String? = null
                try {
                    if (serviceSpecificInfo != null) {
                        val ssiStr = String(serviceSpecificInfo, StandardCharsets.UTF_8)
                        // 解析形如 key=value;key2=value2 的 ssi，取 dev=xxx
                        ssiStr.split(';').forEach { token ->
                            val kv = token.split('=')
                            if (kv.size == 2 && kv[0].trim() == "dev") devId = kv[1].trim()
                        }
                    }
                } catch (_: Throwable) {}
                if (!devId.isNullOrEmpty()) {
                    peerIds.add(devId!!)
                    subIdToPeer[devId!!] = peerHandle
                }
                val totalPeers = peerIds.size
                Log.d(tag, "service discovered; peers=$totalPeers")
                emit(mapOf("type" to "discovered", "peers" to totalPeers))
                
                // 注册到 DataPathManager（API 29+）
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val session = sub
                    if (session != null) {
                        val peerId = dataPathManager?.registerPeer(peerHandle, devId, session)
                        Log.d(tag, "Registered peer in DataPathManager: peerId=$peerId, devId=$devId")
                    }
                }
                // 使用订阅会话直接发送握手（仅对未握手的设备）
                val targetId = devId ?: (peerHandle.hashCode().toString())
                if (!handshakedIds.contains(targetId)) {
                    handshakedIds.add(targetId)
                    val id = msgId.getAndIncrement()
                    val data = "hello from sub".toByteArray(StandardCharsets.UTF_8)
                    try { sub?.sendMessage(peerHandle, id, data) } catch (_: Throwable) {}
                }
            }

            override fun onMessageSendSucceeded(messageId: Int) {
                Log.d(tag, "sub send ok id=$messageId")
                emit(mapOf("type" to "send", "via" to "subscribe", "result" to "ok", "id" to messageId))
            }

            override fun onMessageSendFailed(messageId: Int) {
                Log.w(tag, "sub send fail id=$messageId")
                emit(mapOf("type" to "send", "via" to "subscribe", "result" to "fail", "id" to messageId))
            }

            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                val text = try { String(message, StandardCharsets.UTF_8) } catch (_: Throwable) { "<bin>" }
                Log.i(tag, "!!! SUBSCRIBE onMessageReceived called !!!")
                Log.i(tag, "Message content: [$text]")
                Log.i(tag, "PeerHandle: ${peerHandle.hashCode()}")
                if (!subPeers.contains(peerHandle)) subPeers.add(peerHandle)
                
                // 检查是否是数据路径协商消息
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    Log.i(tag, "Checking if message is DATA_PATH_REQUEST...")
                    if (text.startsWith("DATA_PATH_REQUEST:")) {
                        Log.i(tag, "!!! DATA_PATH_REQUEST detected !!!")
                        // 收到数据路径请求,自动响应
                        val parts = text.split(":")
                        if (parts.size >= 2) {
                            val requesterDevId = parts[1]
                            Log.i(tag, "!!! Parsed requester deviceId: $requesterDevId !!!")
                            
                            // 检查是否已经处理过此设备的请求
                            if (processedDataPathRequests.contains(requesterDevId)) {
                                Log.i(tag, "Already processed DATA_PATH_REQUEST from $requesterDevId, ignoring")
                                return // 已处理，避免重复响应
                            }
                            processedDataPathRequests.add(requesterDevId)
                            
                            // 找到对应的 peerId
                            val session = sub
                            Log.i(tag, "Subscribe session exists: ${session != null}")
                            if (session != null) {
                                Log.i(tag, "Calling DataPathManager.registerPeer...")
                                val peerId = dataPathManager?.registerPeer(peerHandle, requesterDevId, session)
                                Log.i(tag, "registerPeer returned: $peerId")
                                if (peerId != null) {
                                    Log.i(tag, "!!! Auto-responding to DATA_PATH_REQUEST, peerId=$peerId !!!")
                                    
                                    // 发送 ACK
                                    try {
                                        val ackMsg = "DATA_PATH_ACK"
                                        val ackData = ackMsg.toByteArray(StandardCharsets.UTF_8)
                                        val ackId = msgId.getAndIncrement()
                                        sub?.sendMessage(peerHandle, ackId, ackData)
                                    } catch (_: Throwable) {}
                                    
                                    // 关键修改：延迟后也调用 openDataPath
                                    // Wi-Fi Aware Data Path 需要双方都调用 requestNetwork()
                                    // 系统会根据 DiscoverySession 类型自动分配 initiator/responder 角色
                                    Log.i(tag, "Scheduling openDataPath for peer $peerId after 200ms delay...")
                                    handler.postDelayed({
                                        Log.i(tag, "!!! Executing delayed openDataPath for peer $peerId !!!")
                                        dataPathManager?.openDataPath(
                                            peerId = peerId,
                                            passphrase = "aiocr_data_path_2024", // 固定passphrase
                                            onSuccess = {
                                                Log.i(tag, "!!! SUCCESS: Auto data path established for peer $peerId !!!")
                                            },
                                            onError = { err ->
                                                Log.e(tag, "!!! ERROR: Auto data path failed for peer $peerId: $err !!!")
                                            }
                                        )
                                    }, 200) // 极短延迟，快速响应
                                }
                            }
                            return // 不再作为普通消息处理
                        }
                    } else if (text == "DATA_PATH_ACK") {
                        Log.d(tag, "Received DATA_PATH_ACK")
                        emit(mapOf("type" to "message", "via" to "subscribe", "text" to "DATA_PATH_ACK"))
                        return
                    }
                }
                
                // 尝试解析信封，新增对端 ID 并上报 peers 变化
                try {
                    val json = org.json.JSONObject(text)
                    val sender = json.optString("sender", "")
                    if (sender.isNotEmpty()) {
                        if (!peerIds.contains(sender)) {
                            peerIds.add(sender)
                            subIdToPeer[sender] = peerHandle
                            emit(mapOf("type" to "discovered", "peers" to peerIds.size))
                        }
                    }
                } catch (_: Throwable) {}
                emit(mapOf("type" to "message", "via" to "subscribe", "text" to text))
            }

            override fun onSessionTerminated() {
                Log.d(tag, "subscribe terminated")
                sub = null
                emit(mapOf("type" to "subscribe", "state" to "terminated"))
            }
        }, handler)
    }

    fun sendMessage(peer: PeerHandle, text: String) {
        val id = msgId.getAndIncrement()
        val data = text.toByteArray(StandardCharsets.UTF_8)
        // 发送前长度预检查，避免抛出系统异常导致 MethodChannel 报错
        try {
            val max = getMaxMessageLength()
            if (max > 0 && data.size > max) {
                Log.w(tag, "precheck too long: size=${data.size} max=$max")
                emit(mapOf("type" to "send", "via" to "precheck", "result" to "too_long", "len" to data.size, "max" to max))
                return
            }
        } catch (_: Throwable) {}
        // 优先使用发现该 peer 的同源会话
        val s = sub
        if (s != null && subPeers.contains(peer)) {
            try {
                s.sendMessage(peer, id, data)
                return
            } catch (t: Throwable) {
                Log.w(tag, "sub send exception: ${t.message}")
                emit(mapOf("type" to "send", "via" to "subscribe", "result" to "exception", "id" to id, "error" to (t.message ?: "error")))
                return
            }
        }
        val p = pub
        if (p != null && pubPeers.contains(peer)) {
            try {
                p.sendMessage(peer, id, data)
                return
            } catch (t: Throwable) {
                Log.w(tag, "publish send exception: ${t.message}")
                emit(mapOf("type" to "send", "via" to "publish", "result" to "exception", "id" to id, "error" to (t.message ?: "error")))
                return
            }
        }
        // 兜底尝试（可能失败）
        try { s?.sendMessage(peer, id, data) } catch (t: Throwable) {
            Log.w(tag, "fallback sub send exception: ${t.message}")
            emit(mapOf("type" to "send", "via" to "subscribe", "result" to "exception", "id" to id, "error" to (t.message ?: "error")))
            return
        }
        try { p?.sendMessage(peer, id, data) } catch (t: Throwable) {
            Log.w(tag, "fallback publish send exception: ${t.message}")
            emit(mapOf("type" to "send", "via" to "publish", "result" to "exception", "id" to id, "error" to (t.message ?: "error")))
            return
        }
    }

    fun broadcast(text: String) {
        // 基于 peerIds 去重，优先使用订阅映射的 handle
        val ids = peerIds.toList()
        var sent = 0
        ids.forEach { id ->
            val h = subIdToPeer[id] ?: pubIdToPeer[id]
            if (h != null) {
                sendMessage(h, text)
                sent++
            }
        }
        Log.d(tag, "broadcast to $sent peers")
        emit(mapOf("type" to "broadcast", "count" to sent))
    }

    fun release() {
        try { pub?.close() } catch (_: Throwable) {}
        try { sub?.close() } catch (_: Throwable) {}
        try { session?.close() } catch (_: Throwable) {}
        pub = null
        sub = null
        session = null
        subPeers.clear()
        pubPeers.clear()
        peerIds.clear()
        subIdToPeer.clear()
        pubIdToPeer.clear()
        handshakedIds.clear()
        
        // 释放数据路径资源
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dataPathManager?.releaseAll()
        }
        
        emit(mapOf("type" to "released"))
    }
    
    // === Data Path 相关方法（API 29+）===
    
    fun listDataPathPeers(): List<Map<String, Any?>>? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dataPathManager?.listPeers()
        } else null
    }
    
    fun openDataPath(peerId: Int, passphrase: String?, onSuccess: (() -> Unit)?, onError: ((String) -> Unit)?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dataPathManager?.openDataPath(peerId, passphrase, onSuccess = onSuccess, onError = onError)
        } else {
            onError?.invoke("Data path requires Android 10+")
        }
    }
    
    fun sendLargeText(peerId: Int, text: String, onSuccess: (() -> Unit)?, onError: ((String) -> Unit)?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dataPathManager?.sendLargeText(peerId, text, onSuccess = onSuccess, onError = onError)
        } else {
            onError?.invoke("Data path requires Android 10+")
        }
    }
    
    fun closeDataPath(peerId: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            dataPathManager?.closeDataPath(peerId)
        }
    }

    private fun parseRoomFromSsi(ssi: String?): String? {
        if (ssi.isNullOrEmpty()) return null
        return try {
            var room: String? = null
            ssi.split(';').forEach { token ->
                val kv = token.split('=')
                if (kv.size == 2 && kv[0].trim() == "room") room = kv[1].trim()
            }
            room
        } catch (_: Throwable) { null }
    }
}
