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
    // 区分不同会话来源的 peer handle，便于使用正确的会话发送消息
    private val subPeers = mutableSetOf<PeerHandle>()
    private val pubPeers = mutableSetOf<PeerHandle>()
    // 基于对端的自带 deviceId 去重（从 SSI 或消息信封解析），映射到最新的 handle
    private val peerIds = mutableSetOf<String>()
    private val subIdToPeer = mutableMapOf<String, PeerHandle>()
    private val pubIdToPeer = mutableMapOf<String, PeerHandle>()
    // 记录已握手过的设备，避免重复发送握手消息
    private val handshakedIds = mutableSetOf<String>()
    private val msgId = AtomicInteger(1)
    private var eventSink: EventChannel.EventSink? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
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
                val text = try { String(message) } catch (_: Throwable) { "<bin>" }
                Log.d(tag, "publish received from peer: $text")
                if (!pubPeers.contains(peerHandle)) pubPeers.add(peerHandle)
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
                val text = try { String(message) } catch (_: Throwable) { "<bin>" }
                Log.d(tag, "sub received: $text")
                if (!subPeers.contains(peerHandle)) subPeers.add(peerHandle)
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
        // 优先使用发现该 peer 的同源会话
        val s = sub
        if (s != null && subPeers.contains(peer)) {
            s.sendMessage(peer, id, data)
            return
        }
        val p = pub
        if (p != null && pubPeers.contains(peer)) {
            p.sendMessage(peer, id, data)
            return
        }
        // 兜底尝试（可能失败）
        try { s?.sendMessage(peer, id, data) } catch (_: Throwable) {}
        try { p?.sendMessage(peer, id, data) } catch (_: Throwable) {}
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
        emit(mapOf("type" to "released"))
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
