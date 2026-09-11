package android.util;

/** Isolated JVM oracle only: replace Android logging, never EXIF or application behavior. */
public final class Log {
    public static boolean isLoggable(String tag, int level) { return false; }
    public static int d(String tag, String message) { return 0; }
    public static int w(String tag, String message) { return 0; }
    public static int w(String tag, String message, Throwable error) { return 0; }
    public static int e(String tag, String message) { return 0; }
    public static int e(String tag, String message, Throwable error) { return 0; }
}
