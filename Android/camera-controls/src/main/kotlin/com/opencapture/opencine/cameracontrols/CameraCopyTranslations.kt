package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.CopyCatalog
import com.opencapture.monitorui.CopyLanguage

/**
 * The settings and connection copy in every language it ships, keyed by the English text.
 *
 * The key is the English string, so edited English stops matching and the operator reads English
 * rather than a stale translation.
 */
internal object CameraCopyTranslations {
    val simplifiedChinese: Map<String, String> =
        mapOf(
            // Connection phase labels.
            "Idle" to "空闲",
            "Scanning for camera…" to "正在搜索相机…",
            "Connecting (Bluetooth)…" to "正在连接（蓝牙）…",
            "Pairing…" to "正在配对…",
            "Approve on the camera screen" to "请在相机屏幕上确认",
            "Reading Wi-Fi credentials…" to "正在读取 Wi-Fi 凭据…",
            "Joining camera Wi-Fi…" to "正在加入相机 Wi-Fi…",
            "Opening datalink…" to "正在建立数据链路…",
            "Connected" to "已连接",
            "Failed" to "连接失败",
            "Failed: " to "连接失败：",
            "Empty" to "空",
            "Not connected" to "未连接",
            // Settings rows.
            "Picture" to "画面",
            "Processing" to "处理",
            "Coming soon..." to "即将推出…",
            "Gyro logging" to "陀螺仪记录",
            "Gyro logs" to "陀螺仪日志",
            "Log gyro with camera recordings" to "随相机录制记录陀螺仪",
            "Mount this phone firmly to the camera. Synchronize exported logs in Gyroflow." to
                "把这台手机牢固地固定在相机上。导出的日志可在 Gyroflow 里同步。",
            "Status" to "状态",
            "Phone mount" to "手机固定",
            "Configure" to "配置",
            "Open" to "打开",
            "Remote shutter" to "远程快门",
            "Auto-Rotate Feed" to "自动旋转画面",
            "Saved motion logs" to "已保存的运动日志",
            "Share a log with the matching camera video, then select its lens and mount orientation in Gyroflow." to
                "把日志和对应的相机视频一起分享出去，然后在 Gyroflow 里选择镜头和固定方向。",
            "Saved feed reports deleted" to "已删除保存的画面报告",
            "Couldn't delete saved feed reports. Please try again." to "无法删除保存的画面报告，请重试。",
            "Optional" to "可选",
            // Cache rows.
            "Checking…" to "检查中…",
            "Could not read the cache." to "无法读取缓存。",
            "Could not clear the cache. Try again." to "无法清除缓存，请重试。",
            "Originals and playback proxies downloaded from the camera." to
                "从相机下载的原始文件和回放代理文件。",
            "Remove downloaded picture files while keeping the clip list." to
                "删除已下载的画面文件，保留片段列表。",
            "Keep originals downloaded for playback." to "回放时保留已下载的原始文件。",
            // Problem report.
            "Report a problem" to "反馈问题",
            "Tell us what happened in the app. Choose whether to include technical details and an email for a reply." to
                "告诉我们 app 里发生了什么。你可以选择是否附上技术细节和用于回复的邮箱。",
            // Settings help, the sheets behind the info icons.
            "Keeps the screen awake while this app is active. Turn off to use the device's normal auto-lock setting. The system may still dim the screen when the device is hot." to
                "app 使用期间保持屏幕常亮。关闭后按系统正常的自动锁屏设置执行。设备过热时系统仍可能自动调暗屏幕。",
            "Waiting for the camera to report its color curve. False color, zebra and LUT exposure return on their own once it does." to
                "正在等待相机上报色彩曲线。上报之后，伪色、斑马纹和 LUT 曝光会自行恢复。",
            "How the live-view frame is enlarged to fill the panel. The camera sends far fewer pixels than the panel has, so something always does this. Off is a plain sample, Fast is a fixed sharpening kernel, and Quality is the OS spatial upscaler.\n\nAI is different in kind: it is a machine-learning model that INFERS detail the camera never captured. It gives the sharpest-looking picture, but the fine texture it adds is invented (plausible rather than real), so it can suggest crispness the lens did not record. Judge critical focus on Quality or Fast, and treat AI as a viewing aid rather than evidence.\n\nOnly the options this device supports are shown." to
                "实时画面如何放大到铺满面板。相机送来的像素远少于面板，所以总要有人做这件事。关闭是直接采样，快速是固定的锐化核，高质量用系统的空间放大。\n\nAI 是另一回事：它用机器学习模型去「推断」相机从未拍到的细节。画面看着最锐利，但补出来的细微纹理是编造的（看似合理而非真实），可能让你误判镜头本身的解析力。要判断合焦，请用高质量或快速，把 AI 当作观看辅助而不是依据。\n\n这里只显示本设备支持的选项。",
            "Optional: send crash, hang, live-feed reports and session health counts to OpenCapture through Sentry. Off by default. Turn off anytime without losing app features. Uploads wait until you leave camera Wi-Fi. Automatic reports exclude all images. No footage or GPS location. Sentry receives the connection IP. See Reporting Privacy below." to
                "可选：通过 Sentry 向 OpenCapture 发送崩溃、卡死、实时画面报告和会话健康计数。默认关闭。随时可以关闭，不影响任何功能。上传会等你离开相机 Wi-Fi 后再进行。自动报告不包含任何图像，不含素材，也不含 GPS 位置。Sentry 会收到连接 IP。详见下方的报告隐私说明。",
            "Optional reliability reports\nWith your consent, configured builds send crash, hang and feed diagnostics, app/OS/device versions and session health counts through Sentry, with a random install identifier that is created when you opt in and deleted when you opt out. Automatic reports exclude all images. No footage, screenshots, raw camera packets or GPS location are included. Sentry receives the connection IP. Event storage uses Germany. Some provider processing may occur internationally.\nTurn reporting off in Operator Setup > System at any time without losing app features. This clears pending SDK uploads and deletes the install identifier, but does not delete reports already received. Contact us privately to request deletion. The website policy explains retention, transfers and your rights." to
                "可选可靠性报告\n在你同意的前提下，已配置的版本会通过 Sentry 发送崩溃、卡死和画面诊断、app/系统/设备版本以及会话健康计数，并附带一个随机安装标识；该标识在你选择加入时创建，退出时删除。自动报告不含任何图像，不含素材、截图、相机原始数据包，也不含 GPS 位置。Sentry 会收到连接 IP，事件存储位于德国，部分处理可能在其他国家进行。\n你可以随时在「操作员设置 › 系统」里关闭报告，不影响任何功能。关闭会清空待上传内容并删除安装标识，但不会删除已经收到的报告。如需删除，请私下联系我们。网站上的隐私政策说明了保留期限、跨境传输和你的权利。",
        )
}

private val CAMERA_CATALOG: CopyCatalog =
    CopyCatalog(mapOf(CopyLanguage.SIMPLIFIED_CHINESE to CameraCopyTranslations.simplifiedChinese))

/** [english] in the operator's language, or [english] itself when the table has no row for it. */
internal fun cameraText(english: String): String = CAMERA_CATALOG.text(english, CopyLanguage.preferred())
