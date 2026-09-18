import androidx.exifinterface.media.ExifInterface;
import java.io.File;
import java.util.Base64;

/** Host-only differential oracle; parsing runs in unmodified AndroidX 1.3.7. */
public final class Oracle {
    public static void main(String[] paths) throws Exception {
        for (String path : paths) {
            byte[] bytes = new ExifInterface(new File(path)).getThumbnailBytes();
            System.out.println(new File(path).getName() + "\t"
                + (bytes == null ? "null" : Base64.getEncoder().encodeToString(bytes)));
        }
    }
}
