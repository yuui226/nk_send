# 源码无任何反射（protocol 为手写 ByteBuffer 编解码，类/成员重命名不影响字节布局），
# ViewModel 构造器由 lifecycle-viewmodel 的 consumer 规则保留（allowobfuscation），
# Manifest 组件（Service/Activity）由 AGP 自动 keep——因此不需要任何业务 -keep，
# 让 R8 对全部代码重命名 + 内联 + 裁剪，提高逆向成本。

# 所有混淆后的类扁平化进无名根包，抹掉包结构信息
-repackageclasses ""

# 保留行号便于崩溃定位（用同批次归档的 mapping.txt 还原）；
# 源文件名统一改写为 "SourceFile"，避免泄露真实 .kt 文件名
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
