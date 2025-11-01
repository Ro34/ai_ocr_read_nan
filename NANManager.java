import android.content.Context;
import android.net.wifi.aware.AttachCallback;
import android.net.wifi.aware.DiscoverySessionCallback;
import android.net.wifi.aware.PeerHandle;
import android.net.wifi.aware.PublishConfig;
import android.net.wifi.aware.PublishSession;
import android.net.wifi.aware.SubscribeConfig;
import android.net.wifi.aware.SubscribeSession;
import android.net.wifi.aware.WifiAwareManager;
import android.net.wifi.aware.WifiAwareSession;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;

public class NANManager {
    private static final String TAG = "NANManager";
    private static final String SERVICE_NAME = "my_nan_service";
    private static final String SERVICE_TYPE = "_nan_service._udp";

    private final WifiAwareManager mWifiAwareManager;
    private WifiAwareSession mAwareSession;
    private PublishSession mPublishSession;
    private SubscribeSession mSubscribeSession;
    private final List<PeerHandle> mPeerHandles = new ArrayList<>();
    private final Handler mHandler = new Handler(Looper.getMainLooper());

    public NANManager(Context context) {
        mWifiAwareManager = (WifiAwareManager) context.getSystemService(Context.WIFI_AWARE_SERVICE);
    }

    // 初始化NAN
    public void initialize() {
        if (mWifiAwareManager == null) {
            Log.e(TAG, "WifiAware is not supported on this device");
            return;
        }

        mWifiAwareManager.attach(new AttachCallback() {
            @Override
            public void onAttached(WifiAwareSession session) {
                Log.d(TAG, "NAN attached successfully");
                mAwareSession = session;
                // 作为服务端发布服务
                publishService();
            }

            @Override
            public void onAttachFailed() {
                Log.e(TAG, "NAN attach failed");
            }
        }, mHandler);
    }

    // 发布服务（服务端）
    private void publishService() {
        if (mAwareSession == null) return;

        PublishConfig config = new PublishConfig.Builder()
                .setServiceName(SERVICE_NAME)
                .setServiceType(SERVICE_TYPE)
                .setPublishType(PublishConfig.PUBLISH_TYPE_BROADCAST)
                .build();

        mAwareSession.publish(config, new DiscoverySessionCallback() {
            @Override
            public void onPublishStarted(PublishSession session) {
                Log.d(TAG, "Service published successfully");
                mPublishSession = session;
            }

            @Override
            public void onMessageReceived(PeerHandle peerHandle, byte[] message) {
                Log.d(TAG, "Received message from peer: " + new String(message));
                // 新客户端连接，添加到列表
                if (!mPeerHandles.contains(peerHandle)) {
                    mPeerHandles.add(peerHandle);
                    Log.d(TAG, "Added new peer. Total peers: " + mPeerHandles.size());
                }
            }

            @Override
            public void onSessionTerminated() {
                Log.d(TAG, "Publish session terminated");
            }
        }, mHandler);
    }

    // 订阅服务（客户端）
    public void subscribeToService() {
        if (mAwareSession == null) return;

        SubscribeConfig config = new SubscribeConfig.Builder()
                .setServiceName(SERVICE_NAME)
                .setServiceType(SERVICE_TYPE)
                .build();

        mAwareSession.subscribe(config, new DiscoverySessionCallback() {
            @Override
            public void onSubscribeStarted(SubscribeSession session) {
                Log.d(TAG, "Subscribed to service successfully");
                mSubscribeSession = session;
            }

            @Override
            public void onServiceDiscovered(PeerHandle peerHandle, byte[] serviceSpecificInfo, List<String> matchFilter) {
                Log.d(TAG, "Discovered service from peer");
                // 发现服务后，发送连接请求
                if (!mPeerHandles.contains(peerHandle)) {
                    mPeerHandles.add(peerHandle);
                    sendMessage(peerHandle, "Hello from client!");
                }
            }

            @Override
            public void onMessageReceived(PeerHandle peerHandle, byte[] message) {
                Log.d(TAG, "Received message: " + new String(message));
            }

            @Override
            public void onSessionTerminated() {
                Log.d(TAG, "Subscribe session terminated");
            }
        }, mHandler);
    }

    // 发送数据到指定设备
    public void sendMessage(PeerHandle peerHandle, String message) {
        if (mPublishSession != null) {
            mPublishSession.sendMessage(peerHandle, 0, message.getBytes());
        } else if (mSubscribeSession != null) {
            mSubscribeSession.sendMessage(peerHandle, 0, message.getBytes());
        }
    }

    // 广播数据到所有已连接设备
    public void broadcastMessage(String message) {
        byte[] data = message.getBytes();
        for (PeerHandle peer : mPeerHandles) {
            sendMessage(peer, message);
        }
        Log.d(TAG, "Broadcast message to " + mPeerHandles.size() + " peers");
    }

    // 释放资源
    public void release() {
        if (mPublishSession != null) {
            mPublishSession.close();
        }
        if (mSubscribeSession != null) {
            mSubscribeSession.close();
        }
        if (mAwareSession != null) {
            mAwareSession.close();
        }
        mPeerHandles.clear();
    }
}
