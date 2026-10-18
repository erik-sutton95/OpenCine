# FrameioNative's natives are exported by the app's Swift library (OpenCineFrameIOAndroid) as
# Java_com_opencapture_opencine_frameio_FrameioNative_<method>, and Swift calls back into
# FrameioNative.sha256 by name (GetMethodID). R8 sees neither side.
-keep class com.opencapture.opencine.frameio.FrameioNative { *; }
