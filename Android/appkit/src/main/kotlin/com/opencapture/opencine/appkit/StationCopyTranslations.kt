package com.opencapture.opencine.appkit

import com.opencapture.monitorui.CopyCatalog
import com.opencapture.monitorui.CopyLanguage

/**
 * The station wizard's copy, keyed by the English text.
 *
 * The key is the English string, so a route whose English is edited stops matching, the operator
 * reads English, and the completeness test reports the orphaned row instead of hiding it.
 */
internal object StationCopyTranslations {
    val simplifiedChinese: Map<String, String> =
        mapOf(
            // Route titles. "Wi-Fi" and "USB-C" are product names and stay as they are.
            "Hotspot" to "热点",
            "Camera Wi-Fi" to "相机 Wi-Fi",
            "HDMI capture" to "HDMI 采集",
            // Route bodies.
            "A router, venue network or another device’s hotspot. Cameras and this phone join the same Wi-Fi." to
                "路由器、场地网络或另一台设备的热点。相机和本机加入同一个 Wi-Fi。",
            "This phone’s hotspot. Works anywhere you have mobile data." to
                "本机热点。只要有移动数据就能用。",
            "This phone joins the camera’s own Wi-Fi. No router or hotspot needed." to
                "本机加入相机自带的 Wi-Fi，不需要路由器或热点。",
            "Plug the camera straight into this phone. Nothing to set up." to
                "把相机直接插到本机。无需任何设置。",
            "A USB HDMI capture device on this phone. Picture only, no camera control." to
                "本机接一个 USB HDMI 采集设备。只有画面，不能控制相机。",
            // Route tags.
            "Best for studios and several cameras" to "适合影棚和多机位",
            "Best on the move" to "适合移动使用",
            "Best in the field with one camera" to "适合单机外拍",
            "Best for a fixed rig" to "适合固定机位",
            "Best when the camera has no network" to "适合相机没有网络时",
            // Route actions.
            "Choose Wi-Fi" to "选择 Wi-Fi",
            "Choose hotspot" to "选择热点",
            "Choose camera Wi-Fi" to "选择相机 Wi-Fi",
            "Choose USB-C" to "选择 USB-C",
            "Choose HDMI capture" to "选择 HDMI 采集",
            // Chooser chrome.
            "How will your cameras connect?" to "相机怎么连接？",
            "How should this camera connect?" to "这台相机怎么连接？",
            "Choose the shared network before adding cameras. Saved passwords stay on this phone." to
                "添加相机前先选好共享网络。保存的密码只留在本机。",
            "Switch setups from the camera’s chips at any time." to
                "随时可以从相机上的标签切换连接方式。",
            "Camera Wi-Fi stays available. Switch setups from the camera’s chips at any time." to
                "相机 Wi-Fi 一直可用。随时可以从相机上的标签切换连接方式。",
            // The prefix a saved route's detail carries.
            "Added" to "已添加",
            // The station screen's own chrome.
            "Choose the network" to "选择网络",
            "SAVED ON THIS PHONE" to "本机已保存",
            "NEARBY" to "附近的网络",
            "Scan again" to "重新扫描",
            "NETWORK" to "网络",
            "BEFORE YOU CONNECT" to "连接前请确认",
            "PASSWORD" to "密码",
            "Password" to "密码",
            "HOTSPOT NAME" to "热点名称",
            "Hotspot name" to "热点名称",
            "HOTSPOT PASSWORD" to "热点密码",
            "THIS PHONE’S HOTSPOT" to "本机热点",
            "IN SETTINGS › HOTSPOT" to "在「设置 › 热点」中",
            "Connected" to "已连接",
            "Connected · password saved" to "已连接 · 密码已保存",
            "Password saved" to "密码已保存",
            "This phone’s current network" to "本机当前网络",
            "This phone joins it too" to "本机也会加入",
            "Shared Wi-Fi" to "共享 Wi-Fi",
            "Connect your cameras" to "连接你的相机",
            "Add setup" to "添加连接方式",
            "Wi-Fi" to "Wi-Fi",
            "Hotspot" to "热点",
            "The camera is looking for networks…" to "相机正在搜索网络…",
            "Turn the camera on to find networks" to "打开相机后才能搜索到网络",
            "No networks found yet" to "还没有发现网络",
            "Networks appear here as it finds them" to "相机找到的网络会出现在这里",
            "The scan did not finish. Try Scan again." to "扫描没有完成，请点「重新扫描」。",
            "Finishing camera scan…" to "正在完成相机扫描…",
            "Connecting…" to "正在连接…",
            "The camera is looking for this phone’s hotspot…" to "相机正在寻找本机热点…",
            "This phone joins first. Every camera you add will use the same Wi-Fi." to "本机先加入网络。之后添加的每台相机都用这个 Wi-Fi。",
            "The camera and this phone must be on the same Wi-Fi." to "相机和本机必须在同一个 Wi-Fi 上。",
            "Saved on this phone. Multiview can reuse it." to "保存在本机，多机位可以复用。",
            "The network name shown in Settings › Hotspot." to "就是「设置 › 热点」里显示的网络名称。",
            "Android keeps it private: copy it from Settings › Hotspot once. It is remembered here." to "Android 不会公开它：从「设置 › 热点」里复制一次，之后本机会记住。",
            "WPA2 or WPA2/WPA3 mixed" to "WPA2 或 WPA2/WPA3 混合",
            "WPA3-only networks can refuse some cameras." to "纯 WPA3 网络可能拒绝部分相机。",
            "Devices can see each other" to "设备之间能互相发现",
            "Guest networks with client isolation block the picture." to "开了客户端隔离的访客网络会挡住画面。",
            "Camera within range" to "相机在信号范围内",
            "The camera leaves its own Wi-Fi and joins this one." to "相机会离开自己的 Wi-Fi 加入这个网络。",
            "Hotspot is on" to "热点已开启",
            "Hotspot not detected yet. It can appear once the camera joins." to "还没有检测到热点，相机加入后可能会显示。",
            "Turn on Hotspot" to "打开热点",
            "Lets the camera join this phone." to "让相机加入本机。",
            "Use the 2.4 GHz band" to "使用 2.4 GHz 频段",
            "Open Settings" to "打开设置",
            "Other network…" to "其他网络…",
            "Other network" to "其他网络",
            "Connect over Wi-Fi" to "通过 Wi-Fi 连接",
            "Connect over Hotspot" to "通过热点连接",
            "Cancel" to "取消",
            "Next" to "下一步",
            "Done" to "完成",
            "Back" to "返回",
            "Network name" to "网络名称",
            "Allow Location to show this phone’s Wi-Fi" to "允许定位才能显示本机的 Wi-Fi 名称",
            "Tap to allow precise location. Only the Wi-Fi name is used." to "点一下允许精确位置，只会用到 Wi-Fi 名称。",
            "Turn on Location to show this phone’s Wi-Fi" to "打开定位才能显示本机的 Wi-Fi 名称",
            "Settings › Location. Only the Wi-Fi name is used." to "「设置 › 定位」。只会用到 Wi-Fi 名称。",
            "Hide password" to "隐藏密码",
            "Show password" to "显示密码",
            "Cameras are using this network. Remove them before changing it." to "有相机正在使用这个网络。请先移除它们再修改。",
            // Interpolated rows: the caller passes the value with String.format.
            "Settings › Apps › %1\$s › Permissions › Location, with Use precise location on. Only the Wi-Fi name is used." to "「设置 › 应用 › %1\$s › 权限 › 定位」，并打开精确位置。只会用到 Wi-Fi 名称。",
            "Every %1\$s camera supports 2.4 GHz." to "每台 %1\$s 相机都支持 2.4 GHz。",
        )
}

private val STATION_CATALOG: CopyCatalog =
    CopyCatalog(mapOf(CopyLanguage.SIMPLIFIED_CHINESE to StationCopyTranslations.simplifiedChinese))

/** [english] in [language], or [english] itself when the table has no row for it. */
internal fun stationText(english: String, language: CopyLanguage): String =
    STATION_CATALOG.text(english, language)
