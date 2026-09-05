import androidx.exifinterface.media.ExifInterface;
import com.ztransfer.preview.*;
import java.io.ByteArrayInputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.*;

/** Executes the cached, unmodified AndroidX 1.3.7 decoder against the compiled shared reader.
 * Logging is the only host shim. No network, Android build config change, or product dependency.
 */
public final class ExifRationalOracle {
    record Tag(int id, int type, int count, int n, int d) {}
    static final int[] IDS = {0x829D, 0x829A, 0x9202, 0x9204, 0x920A};
    static final PreviewExifTag[] TAGS = {PreviewExifTag.F_NUMBER, PreviewExifTag.EXPOSURE_TIME,
        PreviewExifTag.APERTURE_VALUE, PreviewExifTag.EXPOSURE_BIAS_VALUE, PreviewExifTag.FOCAL_LENGTH};
    static final String[] NAMES = {ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_EXPOSURE_TIME,
        ExifInterface.TAG_APERTURE_VALUE, ExifInterface.TAG_EXPOSURE_BIAS_VALUE, ExifInterface.TAG_FOCAL_LENGTH};
    static int checked;

    static byte[] tiff(List<Tag> tags, boolean little) {
        ByteBuffer b = ByteBuffer.allocate(32 + tags.size() * 28).order(little ? ByteOrder.LITTLE_ENDIAN : ByteOrder.BIG_ENDIAN);
        b.put((byte)(little ? 73 : 77)).put((byte)(little ? 73 : 77)).putShort((short)42).putInt(8);
        b.putShort((short)1).putShort((short)0x8769).putShort((short)4).putInt(1).putInt(26).putInt(0);
        b.putShort((short)tags.size());
        for (int i = 0; i < tags.size(); i++) {
            Tag tag = tags.get(i); int body = 32 + tags.size() * 12 + i * 16;
            b.position(28 + i * 12);
            b.putShort((short)tag.id()).putShort((short)tag.type()).putInt(tag.count()).putInt(body);
            b.putInt(body, tag.n()).putInt(body + 4, tag.d());
        }
        return b.array();
    }
    static byte[] jpeg(byte[] tiff) {
        ByteBuffer b = ByteBuffer.allocate(tiff.length + 14);
        b.putShort((short)0xFFD8).putShort((short)0xFFE1).putShort((short)(tiff.length + 8));
        b.put(new byte[]{69,120,105,102,0,0}).put(tiff).putShort((short)0xFFD9);
        return b.array();
    }
    static Float originalFloat(String raw) {
        if (raw == null) return null;
        try {
            int slash = raw.indexOf('/');
            if (slash <= 0) return Float.parseFloat(raw);
            float n = Float.parseFloat(raw.substring(0, slash));
            float d = Float.parseFloat(raw.substring(slash + 1));
            return d == 0 ? null : n / d;
        } catch (NumberFormatException invalid) { return null; }
    }
    static void check(byte[] bytes, String description) throws Exception {
        ExifInterface android = new ExifInterface(new ByteArrayInputStream(bytes));
        PreviewExifRationalValues actual = PreviewExifRationalReader.INSTANCE.read(
            (offset, count) -> Arrays.copyOfRange(bytes, Math.toIntExact(offset), Math.toIntExact(offset) + count), bytes.length);
        if (!actual.getComplete()) throw new AssertionError(description + ": incomplete reader");
        NativePreviewExifValues expectedValues = new NativePreviewExifValues();
        NativePreviewExifValues actualValues = new NativePreviewExifValues();
        for (int i = 0; i < TAGS.length; i++) {
            String expected = android.getAttribute(NAMES[i]);
            if (!Objects.equals(originalFloat(expected), originalFloat(actual.value(TAGS[i])))) {
                throw new AssertionError(description + " " + NAMES[i] + ": Android=" + expected + " Native=" + actual.value(TAGS[i]));
            }
            expectedValues.set(TAGS[i], expected);
        }
        actual.applyTo(actualValues);
        PreviewExifDecimalFormatter formatter = (value, digits, root) -> String.format(Locale.ROOT, "%." + digits + "f", value);
        if (!Objects.equals(NativePreviewExifBridge.INSTANCE.metadata(expectedValues, formatter),
                NativePreviewExifBridge.INSTANCE.metadata(actualValues, formatter))) {
            throw new AssertionError(description + ": visible preview differs");
        }
        checked++;
    }
    static void variants(List<Tag> tags, String name) throws Exception {
        for (boolean little : new boolean[]{true, false}) {
            byte[] bytes = tiff(tags, little);
            check(bytes, name + " TIFF little=" + little);
            check(jpeg(bytes), name + " JPEG little=" + little);
        }
    }
    public static void main(String[] args) throws Exception {
        variants(List.of(new Tag(0x9204, 10, 1, 36_293_949, 725_879_001)), "EV visibility boundary");
        variants(List.of(new Tag(0x9204, 10, 1, Integer.MIN_VALUE, -1), new Tag(0x920A, 5, 1, -1, -2)), "signed/unsigned");
        for (int count : new int[]{0,1,2}) {
            List<Tag> tags = new ArrayList<>();
            for (int i = 0; i < IDS.length; i++) tags.add(new Tag(IDS[i], i == 3 ? 10 : 5, count, 99, 0));
            variants(tags, "zero denominator count=" + count);
        }
        variants(List.of(new Tag(0x9204, 7, 1, -2, 3), new Tag(0x9204, 5, 1, 20, 1),
            new Tag(0x920A, 5, 1, 20, 1), new Tag(0x920A, 5, 1, 85, 1)), "undefined/duplicate/type rejection");
        Random random = new Random(0xEF17);
        for (int caseId = 0; caseId < 500; caseId++) {
            List<Tag> tags = new ArrayList<>();
            for (int i = 0; i < IDS.length; i++) tags.add(new Tag(IDS[i], i == 3 ? 10 : 5, 1, random.nextInt(), random.nextInt()));
            variants(tags, "seeded case=" + caseId);
        }
        System.out.println("PASS AndroidX 1.3.7 actual decoder: " + checked + " TIFF/JPEG samples, five numeric fields and visible preview equality");
        System.out.println("NOT PROVEN: ImageIO/Swift/Native execution, multi-APP1/complex IFD traversal or malformed-file equivalence.");
    }
}
