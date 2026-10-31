package com.opencapture.monitorui

/**
 * The translated shared copy, keyed by the English text the copy objects hold.
 *
 * The key is the English string itself, not a symbolic name, so a translation can never drift from
 * a key: if the English copy is edited the row stops matching, the operator reads English, and
 * `CopyTranslationTest` reports the row as unused instead of leaving a stale translation in place.
 *
 * Style rules carried from the copy objects: operator copy never uses the em dash character, and a
 * sentence keeps the punctuation of the English it replaces so a host can swap languages without
 * reflowing a sheet.
 */
internal object CopyTranslations {
    val simplifiedChinese: Map<String, String> =
        mapOf(
            // Header chrome.
            "Back to media" to "返回素材",
            "Favorite clip" to "收藏片段",
            "Clip information" to "片段信息",
            "Share clip" to "分享片段",
            "SHARE" to "分享",
            "Delete clip from camera" to "从相机删除片段",
            // Clip information sheet.
            "CLIP INFO" to "片段信息",
            "Close clip information" to "关闭片段信息",
            // Deletion confirmation.
            "Delete this clip from the camera?" to "从相机删除这个片段？",
            "Delete" to "删除",
            "Cancel" to "取消",
            "Cancel deletion" to "取消删除",
            "Delete from the camera card" to "从相机存储卡删除",
            // Transport.
            "Back 15 seconds" to "后退 15 秒",
            "Forward 15 seconds" to "前进 15 秒",
            "Play" to "播放",
            "Pause" to "暂停",
            "Restart clip" to "重新播放片段",
            "Previous clip" to "上一个片段",
            "Next clip" to "下一个片段",
            // Options.
            "Conform preview" to "变速预览",
            "Close conform preview" to "关闭变速预览",
            "Mute" to "静音",
            "Unmute" to "取消静音",
            "Loop playback" to "循环播放",
            "On" to "开",
            "Off" to "关",
            "Hide playback controls" to "隐藏播放控件",
            "A restore control stays in the corner" to "角落会保留一个恢复按钮",
            "Show playback controls" to "显示播放控件",
            // Conform preview panel.
            "CONFORM PREVIEW" to "变速预览",
            "Real time" to "实时速度",
            // Scrubber.
            "Playback position" to "播放位置",
            // Rating shade.
            "Show star rating" to "显示星级评分",
            "Hide star rating" to "隐藏星级评分",
            // Units composed by MonitorPlaybackStrings, not copy constants of their own.
            MonitorPlaybackCopyUnits.RATE to "评分",
            MonitorPlaybackCopyUnits.SECONDS to "秒",
            MonitorPlaybackCopyUnits.STAR to "星",
            MonitorPlaybackCopyUnits.STARS to "星",
        )
}
