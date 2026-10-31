package com.opencapture.monitorui

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * The language the shared screens render copy in.
 *
 * The default follows the device, so an app that does nothing shows the operator's language. A
 * host that offers its own picker provides this value around the shared screens instead.
 */
internal val LocalCopyLanguage = staticCompositionLocalOf { CopyLanguage.preferred() }
