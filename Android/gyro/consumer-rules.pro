# GyroNative's natives are exported by the app's Swift library (OpenCineGyroAndroid) as
# Java_com_opencapture_opencine_gyro_GyroNative_<method>. R8 sees neither side.
-keep class com.opencapture.opencine.gyro.GyroNative { *; }
