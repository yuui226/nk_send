# 协议层依赖字节布局与反射式访问，全部保留
-keep class com.ztransfer.protocol.** { *; }
-keepclassmembers class com.ztransfer.protocol.** { *; }

# ViewModel 由 androidx 反射实例化（AndroidViewModel(Application)）
-keep class com.ztransfer.viewmodel.** { *; }

# 前台服务由系统按类名启动
-keep class com.ztransfer.service.** { *; }

# 保留行号，便于线上崩溃定位
-keepattributes SourceFile,LineNumberTable
