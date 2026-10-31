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

internal object CameraHelpTranslations {
    /** Keyed by the copy member's name, so an edited English line cannot orphan a row. */
    val simplifiedChinese: Map<String, String> = mapOf(
            "CURRENT_TRANSPORT" to "Pocket 先用蓝牙配对，再用相机自带的 Wi-Fi 传 HEVC。此版本不含 USB-C、热点和 HDMI 采集。",
            "PHASE" to "当前 BLE → Wi-Fi → 数据链路 握手走到哪一步。",
            "CAMERA_WIFI" to "本次会话加入的 SSID。密码保存在本机的 Android Keystore 里。",
            "SAVED_CAMERAS" to "在主页列表里配对。设置页不会发起新的配对，配对留在「你的相机」里。",
            "EDIT_VIEW" to "打开监视画面，逐个显示或隐藏每个元素。",
            "FRAME_IO" to "在分享弹窗里登录后即可上传片段。Frame.io 需要联网，所以上传时手机会暂时离开相机 Wi-Fi。",
            "RECORD_CONFIRMATION" to "开始或停止录制前先确认，避免误触。",
            "SHOOTING_MODE" to "在视频、照片和定时模式之间切换相机。相机会回报当前模式，所以在机身上改动后这里也会跟着变。",
            "HAPTICS" to "开关、设置和云台到限位时的短促确认振动。连接手柄时到限位还会震一下。",
            "JOYSTICK_SENSITIVITY" to "摇杆推到底能让云台移动多远，屏幕摇杆和手柄都算。小幅推动很慢，推到底最快。4 是实机手感，5 更快到全速，1 最慢。",
            "VIRTUAL_JOYSTICK_SIZE" to "屏幕摇杆的大小。默认中号。大号更好按，小号留给画面更多空间。",
            "VIRTUAL_JOYSTICK_INVERT_PAN" to "反转屏幕摇杆的左右方向。默认关闭。手柄不受影响。",
            "VIRTUAL_JOYSTICK_INVERT_TILT" to "反转屏幕摇杆的上下方向。默认关闭。手柄不受影响。",
            "VIRTUAL_JOYSTICK_DEADZONE" to "忽略中心附近的小幅移动。默认 8%。调大可以让中心更不敏感。",
            "VIRTUAL_JOYSTICK_RESPONSE" to "标准保持当前手感。线性响应均匀。精细让小幅度更柔和。",
            "GIMBAL_JOYSTICK" to "用哪个摇杆控制左右和俯仰。默认左摇杆，另一个摇杆不会动云台。",
            "GAMEPAD" to "已连接的手柄。选定的云台摇杆控制左右与俯仰。Cross/A 录制，Circle/B 回中，Square/X 旋转 180 度，Triangle/Y 跟踪人脸，L1/R1 变焦拉远/拉近，L2/R2 按住变焦（按得越深越快），十字键上下调 ISO、左右调快门。拔掉后摇杆回位。你按住屏幕摇杆时以屏幕为准。",
            "HDR_DISPLAY" to "这是户外屏幕亮度，不是调色。波形、直方图、RGB 分量、矢量、斑马纹和伪色读的仍是相机解码后的信号，所以请据此判断曝光，而不是看画面有多亮。录屏会退回普通 SDR 画面，避免文件被当成 HDR。这不是相机的 HDR/HLG 色彩模式。默认关闭。",
            "THEME" to "深灰现场监视器外观，天蓝色点缀，针对片场低反光调校。",
            "SUPPORT" to "连接、实时画面、控制和疑难排查。",
            "REPORT" to "在 GitHub 上为本项目打开公开的问题反馈表单。",
            "REPORT_PROBLEM" to "说说发生了什么。除非你自己附上，技术细节不会被包含。最多可以附三张照片。发送不会开启自动报告。",
            "RELIABILITY_UNAVAILABLE" to "此版本无法发送自动报告。你仍然可以分享或删除存在本机上的报告。",
            "FEATURE" to "在本项目的功能建议讨论区里提出想法。",
            "SOURCE" to "在 GitHub 上查看项目。如果相机 Wi-Fi 是唯一网络，打开它可能会离开相机 Wi-Fi。",
            "LINK_HEALTH" to "相机链路此刻的健康度：看的是投递，不是无线电 RSSI。",
            "CLEAR_CACHE" to "清除所有相机的缓存片段、缩略图和相机索引。连接后相机会重新加载素材库。",
            "LUT_LOOK" to "效果只作用在本机上，相机里的文件不变。",
            "APP_VERSION" to "当前的 app 构建版本，来自原生项目的元数据。",
            "LOCAL_CACHE" to "本机上所有相机的缓存片段、缩略图和相机索引。",
            "CACHE_FULL_RESOLUTION" to "打开片段时下载相机里的原始文件。关闭则只保留 720p 代理以节省空间。分享需要原始文件，如果没缓存就先连接相机。",
            "FALSE_COLOR_SCALE" to "相机的色彩模式会自动选择 D-Log、D-Log2、Rec.709 或 HLG。CineStop 以 18% 灰为中心画五档，读的是相机的 log 曲线：深绿 −2、黄绿 −1、18% 为灰、浅粉 +1（肤色）、柔黄 +2（肤色上限）。红色是过曝削顶，紫色是暗部压死；其余暗部为深灰、其余高光为浅灰。Video 在亮度灰阶上画视频电平的 IRE 条纹（绿 41–48、粉 61–70、红为削顶）。IRE 在亮度灰阶上画六个视频电平区间：紫为压死、蓝为近黑、绿为 18% 灰、粉为过一档、黄为接近削顶、红为削顶。在 log 上，Video 和 IRE 读的是相机的 Rec.709 效果（709）或原始信号（LOG），在「读取」里切换。Limits 只画暗部和高光警告，不改其他颜色。",
            "FALSE_COLOR_REFERENCE" to "伪色开启时在画面上显示一条紧凑的色标。",
            "PEAKING_SENSITIVITY" to "灵敏度越高越能抓到细边缘，但复杂场景里也更容易显得噪。",
            "PEAKING_COLOR" to "选择在你常拍场景里最显眼的边缘颜色。",
            "ZEBRA_UNITS" to "在原生 0-255 编码值和 0-100 监看 IRE 标尺之间切换。",
            "ZEBRA_HIGHLIGHT" to "高光斑马纹：补偿当前 log 曲线后，亮部细节接近削顶时提醒。",
            "ZEBRA_MIDTONE" to "中间调斑马纹：给出经曲线补偿的参考带，用于人脸或主体曝光。",
            "WAVEFORM_BRIGHTNESS" to "在强光下波形看不清时，提高轨迹亮度。",
            "PARADE_BRIGHTNESS" to "通道分离看不清时，提高轨迹亮度。",
            "VECTORSCOPE_ZOOM" to "只放大色度轨迹，刻度盘保持原比例。矢量示波器读的是监视画面（你当前的 LUT 或内置显示色调映射），那里色度才有意义。",
            "VECTORSCOPE_BRIGHTNESS" to "色度图看不清时，提高轨迹亮度。",
            "TRAFFIC_LIGHTS_COMPENSATION" to "通道指示亮起前允许的压死/削顶容差档数。与直方图的红绿灯共用。",
        )
}

private val CAMERA_HELP_CATALOG: CopyCatalog =
    CopyCatalog(mapOf(CopyLanguage.SIMPLIFIED_CHINESE to CameraHelpTranslations.simplifiedChinese))

/** The help member [name] in the operator's language, else the English it already holds. */
internal inline fun cameraHelp(name: String, english: () -> String): String {
    val text = english()
    return CAMERA_HELP_CATALOG.text(name, CopyLanguage.preferred()).takeIf { it != name } ?: text
}

private val CAMERA_CATALOG: CopyCatalog =
    CopyCatalog(mapOf(CopyLanguage.SIMPLIFIED_CHINESE to CameraCopyTranslations.simplifiedChinese))

/** [english] in the operator's language, or [english] itself when the table has no row for it. */
internal fun cameraText(english: String): String = CAMERA_CATALOG.text(english, CopyLanguage.preferred())
