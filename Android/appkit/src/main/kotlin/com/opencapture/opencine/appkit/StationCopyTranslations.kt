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
        )
}

private val STATION_CATALOG: CopyCatalog =
    CopyCatalog(mapOf(CopyLanguage.SIMPLIFIED_CHINESE to StationCopyTranslations.simplifiedChinese))

/** [english] in [language], or [english] itself when the table has no row for it. */
internal fun stationText(english: String, language: CopyLanguage): String =
    STATION_CATALOG.text(english, language)
