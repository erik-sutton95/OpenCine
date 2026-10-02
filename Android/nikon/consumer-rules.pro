# NikonNative's natives are exported by the app's Swift library (OpenCineNikonAndroid) as
# Java_com_opencapture_opencine_nikon_NikonNative_<method>, and Swift calls back into the
# listeners it takes (session, events, live frames, media transfer) and into the USB byte
# transport by method name (GetMethodID). R8 sees neither side, so keep the whole module
# (the app kept its core-api seam and JNI bridge packages the same way before the move).
-keep class com.opencapture.opencine.nikon.** { *; }
# The app's implementations of those callbacks and of the USB transport (Swift resolves their
# methods on the object's own class).
-keep class * implements com.opencapture.opencine.nikon.UsbPtpTransport { *; }
-keep class * implements com.opencapture.opencine.nikon.NikonNative$SessionListener { *; }
-keep class * implements com.opencapture.opencine.nikon.NikonNative$SessionEventListener { *; }
-keep class * implements com.opencapture.opencine.nikon.NikonNative$LiveFrameListener { *; }
-keep class * implements com.opencapture.opencine.nikon.NikonNative$MediaTransferListener { *; }
