# StreamingNative's natives are exported by the app's Swift library (OpenCineStreamingAndroid) as
# Java_com_opencapture_opencine_streaming_StreamingNative_<method>. R8 sees neither side.
-keep class com.opencapture.opencine.streaming.StreamingNative { *; }
