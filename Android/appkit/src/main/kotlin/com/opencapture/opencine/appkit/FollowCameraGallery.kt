package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

/**
 * The live screen follows the camera body's own gallery from its first change after the screen
 * appears ([ShellModel.followCameraGallery]); the state it appeared with is not a change. Swift
 * apps call `followCameraGallery(open:)` from `onChange`, which also skips the initial value.
 */
@Composable
public fun FollowCameraGallery(open: Boolean, shell: ShellModel) {
    var followed by remember { mutableStateOf(open) }
    LaunchedEffect(open) {
        if (open == followed) return@LaunchedEffect
        followed = open
        shell.followCameraGallery(open)
    }
}
