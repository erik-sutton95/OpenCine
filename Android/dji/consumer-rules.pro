# DjiNative's natives are exported by the app's Swift library as
# Java_com_opencapture_opencine_dji_DjiNative_<method>: keep the class and member names.
-keep class com.opencapture.opencine.dji.DjiNative { *; }
# Connection stage names reach diagnostics and reports by name.
-keep class com.opencapture.opencine.dji.ConnectionPhase { *; }
