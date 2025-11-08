Wi-Fi 感知概览
WLAN 感知功能使搭载 Android 8.0（API 级别 26）及更高版本的设备能够发现彼此并直接进行连接，它们之间无需任何其他类型的连接。Wi-Fi 感知也称为“邻近感知网络”(NAN)。

WLAN 感知网络的工作原理是与邻近设备组建集群，如果设备是某个区域的第一个设备，则创建一个新集群。此集群行为适用于整个设备，由 WLAN 感知系统服务管理；应用无法控制集群行为。应用使用 WLAN 感知 API 与 WLAN 感知系统服务通信，后者管理设备上的 WLAN 感知硬件。

应用可通过 WLAN 感知 API 执行以下操作：

发现其他设备：此 API 具有查找其他附近设备的机制。此过程会在一台设备发布一项或多项可发现服务时启动。然后，当设备订阅一项或多项服务并进入发布者的 WLAN 范围时，订阅者会收到一条告知已发现匹配发布者的通知。在订阅者发现发布者后，订阅者可以发送短消息或与发现的设备建立网络连接。设备可以既是发布者又是订阅者。
创建网络连接：两台设备发现彼此后，可以创建没有接入点的双向 WLAN 感知网络连接。
与蓝牙连接相比，WLAN 感知网络连接支持的覆盖范围更广，支持的吞吐率更高。这些类型的连接适用于在用户之间共享大量数据的应用，例如照片共享应用。

Android 13（API 级别 33）增强功能

在搭载 Android 13（API 级别 33）及更高版本且支持即时通信模式的设备上，应用可以使用 PublishConfig.Builder.setInstantCommunicationModeEnabled() 和 SubscribeConfig.Builder.setInstantCommunicationModeEnabled() 方法为发布者或订阅者发现会话启用或停用即时通信模式。即时通信模式可加快消息交换、服务发现以及作为发布者或订阅者发现会话一部分的任何数据路径设置。如需确定设备是否支持即时通信模式，请使用 isInstantCommunicationModeSupported() 方法。

注意： 由于即时通信模式会消耗更多电量，因此从发布者或订阅者发现会话开始时起，此模式仅保持启用状态 30 秒。
Android 12（API 级别 31）增强功能

Android 12（API 级别 31）增强了 Wi-Fi 感知功能：

在搭载 Android 12（API 级别 31）或更高版本的设备上，您可以使用 onServiceLost() 回调，以便在应用因服务停止或移出范围而失去已发现的服务时收到提醒。
简化了 Wi-Fi Aware 数据路径的设置。较低的版本使用 L2 消息功能来提供发起方的 MAC 地址，由此导致了延迟。在搭载 Android 12 及更高版本的设备上，可以将响应方（服务器）配置为接受任何对等方，也就是说，它不需要预先知道发起方的 MAC 地址。这可加快数据路径启动，并只需一个网络请求即可实现多个点对点链接。
在 Android 12 或更高版本上运行的应用可以使用 WifiAwareManager.getAvailableAwareResources() 方法来获取当前可用的数据路径、发布会话和订阅会话的数量。这有助于应用确定是否有足够的可用资源来执行所需的功能。
初始设置

如需将应用设置为使用 WLAN 感知发现和网络，请执行以下步骤：

在应用的清单中请求以下权限：

<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
<uses-permission android:name="android.permission.INTERNET" />
<!-- If your app targets Android 13 (API level 33)
     or higher, you must declare the NEARBY_WIFI_DEVICES permission. -->
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES"
                 <!-- If your app derives location information from
                      Wi-Fi APIs, don't include the "usesPermissionFlags"
                      attribute. -->
                 android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
                 <!-- If any feature in your app relies on precise location
                      information, don't include the "maxSdkVersion"
                      attribute. -->
                 android:maxSdkVersion="32" />
使用 PackageManager API 检查设备是否支持 WLAN 感知功能，如下所示：

检查 WLAN 感知功能当前是否可用。设备上可能存在 WLAN 感知功能，但当前可能无法使用，因为用户已停用 WLAN 或位置信息服务。如果正在使用 WLAN 直连、SoftAP 或网络共享，某些设备可能不支持 WLAN 感知功能，具体取决于其硬件和固件功能。如需检查 WLAN 感知功能当前是否可用，请调用 isAvailable()。

WLAN 感知功能的可用性随时都可能发生变化。您的应用应注册 BroadcastReceiver 才能收到每当可用性发生变化时发送的 ACTION_WIFI_AWARE_STATE_CHANGED。应用收到该广播 intent 后，应舍弃所有现有会话（假设 WLAN 感知服务已中断），然后检查当前的可用性状态并相应地调整其行为。例如：

如需了解详情，请参阅广播。

注意： 确保您在检查可用性之前注册广播接收器。否则，在一段时间内，应用可能会认为 WLAN 感知功能可用，但在可用性发生变化时不会收到通知。
获取会话

要开始使用 WLAN 感知功能，您的应用必须通过调用 attach() 获取 WifiAwareSession。此方法会执行以下操作：

开启 WLAN 感知硬件。
加入或组建 WLAN 感知集群。
创建一个包含唯一命名空间的 WLAN 感知会话，该命名空间充当在其中创建的所有发现会话的容器。
如果应用成功附加，则系统会执行 onAttached() 回调。该回调提供了一个 WifiAwareSession 对象，您的应用应该将该对象用于所有后续会话操作。应用可以使用会话来发布服务或订阅服务。

您的应用只能调用 attach() 一次。如果您的应用调用 attach() 多次，则应用会为每次调用接收不同的会话，且每个会话都有自己的命名空间。这可能适用于复杂的情况，但通常应该避免。

注意： 只要有活动的会话，系统就会与 WLAN 感知集群保持同步。此集群操作会消耗资源和电量。为了节省资源，请在不再需要会话时调用 WifiAwareSession.close()。
发布服务

如需使服务可被发现，请调用 publish() 方法，该方法采用以下参数：

PublishConfig 指定服务名称和其他配置属性，例如匹配过滤器。
DiscoverySessionCallback 指定发生事件时（例如订阅者收到消息时）要执行的操作。
示例如下：

如果发布成功，则会调用 onPublishStarted() 回调方法。

发布后，当运行匹配订阅者应用的设备进入发布设备的 WLAN 范围时，订阅者会发现该服务。当订阅者发现发布者时，发布者不会收到通知；但是，如果订阅者向发布者发送消息，则发布者会收到通知。发生这种情况时，系统会调用 onMessageReceived() 回调方法。您可以使用此方法的 PeerHandle 参数向订阅者回发消息或创建与订阅者的连接。

如需停止发布服务，请调用 DiscoverySession.close()。 发现会话与其父级 WifiAwareSession 关联。如果父级会话关闭，其关联的发现会话也会随之关闭。尽管舍弃的对象也会关闭，但系统无法保证超出范围的会话何时关闭，因此我们建议您明确调用 close() 方法。

订阅服务

如需订阅服务，请调用 subscribe() 方法，该方法采用以下参数：

SubscribeConfig 指定要订阅的服务的名称和其他配置属性，例如匹配过滤器。
DiscoverySessionCallback 指定发生事件时（例如发现发布者时）要执行的操作。
示例如下：

如果订阅操作成功，系统会在您的应用中调用 onSubscribeStarted() 回调。由于您可以使用回调中的 SubscribeDiscoverySession 参数在应用发现发布者后与之进行通信，因此您应该保存此引用。您可以随时通过对发现会话调用 updateSubscribe() 来更新订阅会话。

此时，您的订阅等待匹配的发布者进入 WLAN 范围。出现这种情况时，系统会执行 onServiceDiscovered() 回调方法。您可以使用此回调中的 PeerHandle 参数向该发布者发送消息或创建与该发布者的连接。

如需停止订阅某项服务，请调用 DiscoverySession.close()。 发现会话与其父级 WifiAwareSession 关联。如果父级会话关闭，其关联的发现会话也会随之关闭。尽管舍弃的对象也会关闭，但系统无法保证超出范围的会话何时关闭，因此我们建议您明确调用 close() 方法。

发送消息

要向另一台设备发送消息，您需要以下对象：

一个 DiscoverySession。您可以通过此对象调用 sendMessage()。您的应用通过发布服务或订阅服务来获取 DiscoverySession。
另一台设备的 PeerHandle，用于传送消息。您的应用通过以下两种方式之一获取另一台设备的 PeerHandle：

您的应用发布服务并接收来自订阅者的消息。您的应用从 onMessageReceived() 回调中获取订阅者的 PeerHandle。
您的应用订阅某项服务。然后，当发现匹配的发布者时，您的应用会从 onServiceDiscovered() 回调中获取发布者的 PeerHandle。
如需发送消息，请调用 sendMessage()。然后，可能会发生以下回调：

当对等设备成功收到消息后，系统会在发送方应用中调用 onMessageSendSucceeded() 回调。
当对等设备收到消息后，系统会在接收方应用中调用 onMessageReceived() 回调。
注意： 消息通常用于轻量级消息传递，因为它们可能无法送达（或无序送达、多次送达）且长度限制在大约 255 个字节。如需确定确切的长度限制，请调用 getMaxServiceSpecificInfoLength()。对于高速双向通信，您的应用应该改为创建连接。
虽然需要 PeerHandle 才能与对等设备进行通信，但您不应依赖它作为对等设备的永久标识符。应用可以使用更高级别的标识符，这些标识符嵌入在发现服务本身或后续消息中。您可以使用 PublishConfig 或 SubscribeConfig 的 setMatchFilter() 或 setServiceSpecificInfo() 方法在发现服务中嵌入标识符。setMatchFilter() 方法会影响发现，而 setServiceSpecificInfo() 方法不会影响发现。

在消息中嵌入标识符意味着修改消息字节数组以包含标识符（例如，作为前几个字节）。

创建连接

WLAN 感知功能支持两个 WLAN 感知设备之间的客户端-服务器网络连接。

要设置客户端-服务器连接，请执行以下操作：

使用 WLAN 感知发现功能（在服务器上）发布服务并（在客户端上）订阅服务。
订阅者发现发布者后，从订阅者向发布者发送消息。
在发布者设备上启动 ServerSocket，并设置或获取其端口：

使用 ConnectivityManager 和 WifiAwareNetworkSpecifier 在发布者设备上请求 WLAN 感知网络，指定发现会话和订阅者的 PeerHandle，后者是您通过订阅者发送的消息获取的：

发布者请求网络后，应向订阅者发送消息。
订阅者收到发布者的消息后，使用与发布者相同的方法在订阅者设备上请求 WLAN 感知网络。创建 NetworkSpecifier 时，请勿指定端口。当网络连接可用、已更改或丢失时，系统会调用相应的回调方法。
对订阅者调用 onAvailable() 方法之后，您可以使用一个 Network 对象打开 Socket 以与发布者设备上的 ServerSocket 进行通信，但您需要知道 ServerSocket 的 IPv6 地址和端口。您可以从 onCapabilitiesChanged() 回调中提供的 NetworkCapabilities 对象中获取这些信息：

完成网络连接后，请调用 unregisterNetworkCallback()。

注意： 构建网络请求和指定所需的网络功能并非 WLAN 感知 API 所特有的操作。如需详细了解如何处理网络请求，请参阅 ConnectivityManager。
对等设备测距和位置感知发现

具有 WLAN RTT 位置功能的设备可以直接测量到对等设备的距离，并利用此信息限制 WLAN 感知服务发现。

WLAN RTT API 支持直接使用 WLAN 感知对等设备的 MAC 地址或 PeerHandle 测量到该设备的距离。

WLAN 感知发现功能可以被限制为仅发现特定地理围栏内的服务。例如，您可以设置地理围栏，以便发现发布 "Aware_File_Share_Service_Name" 服务且距离在 3 米（指定为 3,000 毫米）到 10 米（指定为 10,000 毫米）之间的设备。

要启用地理围栏，发布者和订阅者都必须采取操作：

发布者必须使用 setRangingEnabled(true) 对发布的服务启用测距。

如果发布者未启用测距，则会忽略订阅者指定的任何地理围栏限制，并执行正常发现而忽略距离。
订阅者必须使用 setMinDistanceMm 和 setMaxDistanceMm 的某种组合来指定地理围栏。

对于任一值，未指定的距离表示没有限制。只指定最大距离意味着最小距离为 0。仅指定最小距离意味着没有最大值。
如果在地理围栏内发现对等服务，则会触发 onServiceDiscoveredWithinRange 回调，从而提供与对等设备的测量距离。然后，可以根据需要调用直接 WLAN RTT API，以便稍后测量距离。