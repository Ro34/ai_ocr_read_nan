package com.example.ai_ocr_read

import android.os.Build
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
	private val channelName = "ai_ocr_read/nan"
	private val eventsName = "ai_ocr_read/nan_events"
	private var nan: NanManager? = null
	private var eventsChannel: EventChannel? = null

	@RequiresApi(Build.VERSION_CODES.O)
	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		val messenger = flutterEngine.dartExecutor.binaryMessenger

		// 事件通道：将 NAN 状态、消息推到 Flutter
		eventsChannel = EventChannel(messenger, eventsName)
		eventsChannel?.setStreamHandler(object : EventChannel.StreamHandler {
			override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
				if (nan == null) nan = NanManager(this@MainActivity)
				nan?.setEventSink(events)
			}

			override fun onCancel(arguments: Any?) {
				nan?.setEventSink(null)
			}
		})

		MethodChannel(messenger, channelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"getMaxMessageLength" -> {
					if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
						result.success(0)
					} else {
						if (nan == null) nan = NanManager(this)
						result.success(nan!!.getMaxMessageLength())
					}
				}
				"isAvailable" -> {
					if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
						result.success(false)
					} else {
						if (nan == null) nan = NanManager(this)
						result.success(nan!!.isAvailable())
					}
				}
				"isLocationEnabled" -> {
					if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
						result.success(false)
					} else {
						if (nan == null) nan = NanManager(this)
						result.success(nan!!.isLocationEnabled())
					}
				}
				"attach" -> {
					if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
						result.error("unsupported", "requires Android O+", null)
					} else {
						if (nan == null) nan = NanManager(this)
						nan!!.attach(onSuccess = { result.success(true) }, onError = { err -> result.error("attach", err, null) })
					}
				}
				"publish" -> {
					if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
						result.error("unsupported", "requires Android O+", null)
					} else {
						if (nan == null) nan = NanManager(this)
						val serviceName = (call.argument<String>("serviceName") ?: "aiocr_room")
						val ssi = call.argument<String>("ssi")
						val broadcast = call.argument<Boolean>("broadcast") ?: true
						nan!!.startPublish(serviceName, ssi, broadcast)
						result.success(true)
					}
				}
				"subscribe" -> {
					if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
						result.error("unsupported", "requires Android O+", null)
					} else {
						if (nan == null) nan = NanManager(this)
						val serviceName = (call.argument<String>("serviceName") ?: "aiocr_room")
						val ssi = call.argument<String>("ssi")
						nan!!.startSubscribe(serviceName, ssi)
						result.success(true)
					}
				}
				"broadcast" -> {
					val text = call.argument<String>("text") ?: "hello"
					try {
						nan?.broadcast(text)
						result.success(true)
					} catch (t: Throwable) {
						result.error("broadcast", t.message, null)
					}
				}
				"release" -> {
					nan?.release()
					result.success(true)
				}
				else -> result.notImplemented()
			}
		}
	}
}
