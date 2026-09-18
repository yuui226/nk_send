package android.os;
public final class Build {
    // Avoid Android Os.lseek on the host. ExifInterface(File) uses the same
    // filename-backed TIFF parser and reopens that filename for thumbnail bytes.
    public static final class VERSION { public static int SDK_INT = 19; }
}
