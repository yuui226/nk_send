package com.ztransfer.build;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import com.android.zipflinger.BytesSource;
import com.android.zipflinger.Entry;
import com.android.zipflinger.ZipArchive;
import com.android.zipflinger.ZipMap;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Random;
import java.util.zip.Inflater;
import java.util.zip.InflaterInputStream;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public final class ReleaseApkOptimizerTest {
    @Rule public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void rawDeflateRoundTripsEmptyTextAndBinaryData() throws Exception {
        byte[] binary = new byte[16_384];
        new Random(19).nextBytes(binary);
        byte[][] inputs = {
            new byte[0],
            "无损压缩，不改变照片或代码。\n".repeat(300).getBytes(StandardCharsets.UTF_8),
            binary,
        };
        for (byte[] input : inputs) {
            byte[] compressed = ReleaseApkOptimizer.compress(input);
            Inflater inflater = new Inflater(true);
            try (InflaterInputStream stream =
                    new InflaterInputStream(new ByteArrayInputStream(compressed), inflater)) {
                assertArrayEquals(input, stream.readAllBytes());
                assertTrue("The raw DEFLATE stream must finish normally", inflater.finished());
            } finally {
                inflater.end();
            }
        }
    }

    @Test
    public void recompressionPreservesEveryPayloadMethodAndStoredAlignment() throws Exception {
        Map<String, FixtureEntry> entries = fixtureEntries();
        Path original = writeArchive("original.apk", entries, true);
        byte[] originalBytes = Files.readAllBytes(original);
        Path candidate = path("candidate.apk");

        ReleaseApkOptimizer.recompress(original, candidate);
        ReleaseApkOptimizer.verifyEntries(original, candidate);

        Map<String, Entry> before = ZipMap.from(original).getEntries();
        Map<String, Entry> after = ZipMap.from(candidate).getEntries();
        assertEquals(before.keySet(), after.keySet());
        for (Map.Entry<String, FixtureEntry> expected : entries.entrySet()) {
            String name = expected.getKey();
            assertArrayEquals(expected.getValue().data, readEntry(candidate, name));
            assertEquals(before.get(name).getCompressionFlag(), after.get(name).getCompressionFlag());
            assertTrue("Recompression must not enlarge " + name,
                    after.get(name).getCompressedSize() <= before.get(name).getCompressedSize());
            if (!after.get(name).isCompressed()) {
                long alignment = name.endsWith(".so") ? 16_384 : 4;
                assertEquals("Stored alignment for " + name,
                        0, after.get(name).getPayloadLocation().first % alignment);
            }
        }
        assertTrue("The deliberately weakly compressed fixture should shrink",
                after.get("classes.dex").getCompressedSize()
                        < before.get("classes.dex").getCompressedSize());
        assertArrayEquals("The source APK must remain untouched", originalBytes, Files.readAllBytes(original));
    }

    @Test
    public void smallEntriesKeepTheirExistingCompressedStreams() throws Exception {
        Path original = writeArchive("small-original.apk", fixtureEntries(), true);
        Path candidate = path("small-candidate.apk");

        ReleaseApkOptimizer.recompress(original, candidate);

        // These entries have too little payload to justify another compression pass.
        // Keeping their original stream also exercises the no-benefit copy path.
        for (String name : new String[] {
                "META-INF/services/example.Service", "assets/预设/测试.np3", "assets/empty-deflated"
        }) {
            assertArrayEquals(name, compressedPayload(original, name), compressedPayload(candidate, name));
        }
    }

    @Test
    public void verificationRejectsChangedPayload() throws Exception {
        Map<String, FixtureEntry> entries = fixtureEntries();
        Path original = writeArchive("payload-original.apk", entries, true);
        entries.put("assets/预设/测试.np3", new FixtureEntry(new byte[] {4, 3, 2, 1}, 1));
        Path changed = writeArchive("payload-changed.apk", entries, true);

        assertThrows(IOException.class, () -> ReleaseApkOptimizer.verifyEntries(original, changed));
    }

    @Test
    public void verificationRejectsMissingAndExtraEntries() throws Exception {
        Map<String, FixtureEntry> entries = fixtureEntries();
        Path original = writeArchive("names-original.apk", entries, true);
        entries.remove("META-INF/services/example.Service");
        Path missing = writeArchive("names-missing.apk", entries, true);
        assertThrows(IOException.class, () -> ReleaseApkOptimizer.verifyEntries(original, missing));

        entries = fixtureEntries();
        entries.put("assets/unexpected", new FixtureEntry(new byte[] {1}, 1));
        Path extra = writeArchive("names-extra.apk", entries, true);
        assertThrows(IOException.class, () -> ReleaseApkOptimizer.verifyEntries(original, extra));
    }

    @Test
    public void verificationRejectsChangedCompressionMethod() throws Exception {
        Map<String, FixtureEntry> entries = fixtureEntries();
        Path original = writeArchive("method-original.apk", entries, true);
        FixtureEntry dex = entries.get("classes.dex");
        entries.put("classes.dex", new FixtureEntry(dex.data, 0));
        Path changed = writeArchive("method-changed.apk", entries, true);

        assertThrows(IOException.class, () -> ReleaseApkOptimizer.verifyEntries(original, changed));
    }

    @Test
    public void verificationRejectsMisalignedStoredPayloads() throws Exception {
        Map<String, FixtureEntry> entries = fixtureEntries();
        Path original = writeArchive("alignment-original.apk", entries, true);
        Path changed = writeArchive("alignment-changed.apk", entries, false);
        long resourceOffset = ZipMap.from(changed).getEntries()
                .get("resources.arsc").getPayloadLocation().first;
        assertTrue("Fixture must actually be misaligned", resourceOffset % 4 != 0);

        assertThrows(IOException.class, () -> ReleaseApkOptimizer.verifyEntries(original, changed));
    }

    @Test
    public void verificationRequiresPageAlignmentForStoredNativeLibraries() throws Exception {
        Map<String, FixtureEntry> entries = fixtureEntries();
        Path original = writeArchive("native-original.apk", entries, true);
        Path changed = writeArchive("native-changed.apk", entries, true, 4);
        long nativeOffset = ZipMap.from(changed).getEntries()
                .get("lib/arm64-v8a/test.so").getPayloadLocation().first;
        assertEquals(0, nativeOffset % 4);
        assertTrue("Fixture must lack 16 KiB alignment", nativeOffset % 16_384 != 0);

        assertThrows(IOException.class, () -> ReleaseApkOptimizer.verifyEntries(original, changed));
    }

    @Test
    public void compressedResourcesAreRejectedBeforeWritingOutput() throws Exception {
        Map<String, FixtureEntry> entries = fixtureEntries();
        entries.put("resources.arsc", new FixtureEntry(new byte[] {1, 2, 3, 4}, 1));
        Path original = writeArchive("compressed-resources.apk", entries, true);
        Path output = path("compressed-resources-output.apk");

        assertThrows(IOException.class, () -> ReleaseApkOptimizer.recompress(original, output));
        assertFalse(Files.exists(output));
    }

    @Test
    public void duplicateNamesAreRejectedBeforeWritingOutput() throws Exception {
        Map<String, FixtureEntry> entries = new LinkedHashMap<>();
        entries.put("first.bin", new FixtureEntry(new byte[] {1}, 0));
        entries.put("other.bin", new FixtureEntry(new byte[] {2}, 0));
        Path duplicate = writeArchive("duplicates.apk", entries, true);
        byte[] bytes = Files.readAllBytes(duplicate);
        replaceAscii(bytes, "other.bin", "first.bin");
        Files.write(duplicate, bytes);
        Path output = path("duplicates-output.apk");

        assertThrows(IOException.class, () -> ReleaseApkOptimizer.recompress(duplicate, output));
        assertFalse(Files.exists(output));
        assertArrayEquals(bytes, Files.readAllBytes(duplicate));
    }

    @Test
    public void recompressionRefusesToOverwriteAnExistingFile() throws Exception {
        Path original = writeArchive("overwrite-original.apk", fixtureEntries(), true);
        Path output = path("existing.apk");
        byte[] sentinel = "already published".getBytes(StandardCharsets.UTF_8);
        Files.write(output, sentinel);

        assertThrows(IOException.class, () -> ReleaseApkOptimizer.recompress(original, output));
        assertArrayEquals(sentinel, Files.readAllBytes(output));
    }

    @Test
    public void invalidUnsignedInputCannotPublishOrAlterExistingFiles() throws Exception {
        Path original = writeArchive("unsigned.apk", fixtureEntries(), true);
        byte[] originalBytes = Files.readAllBytes(original);
        Path output = path("published.apk");
        byte[] sentinel = "previous verified APK".getBytes(StandardCharsets.UTF_8);
        Files.write(output, sentinel);
        Path rootWithoutKeys = temporaryFolder.newFolder("empty-repository").toPath();

        assertThrows(Exception.class,
                () -> ReleaseApkOptimizer.optimize(original, output, rootWithoutKeys));
        assertArrayEquals(originalBytes, Files.readAllBytes(original));
        assertArrayEquals(sentinel, Files.readAllBytes(output));
    }

    private Map<String, FixtureEntry> fixtureEntries() {
        Map<String, FixtureEntry> result = new LinkedHashMap<>();
        // This first local header ensures an archive without alignment has an unaligned ARSC.
        result.put("x", new FixtureEntry(new byte[0], 0));
        result.put("resources.arsc", new FixtureEntry(new byte[] {1, 2, 3, 4, 5}, 0));
        result.put("lib/arm64-v8a/test.so", new FixtureEntry(new byte[] {0x7f, 'E', 'L', 'F'}, 0));
        byte[] block = new byte[8_192];
        new Random(71).nextBytes(block);
        byte[] dexLikePayload = new byte[block.length * 24];
        for (int offset = 0; offset < dexLikePayload.length; offset += block.length) {
            System.arraycopy(block, 0, dexLikePayload, offset, block.length);
        }
        result.put("classes.dex", new FixtureEntry(dexLikePayload, 1));
        result.put("META-INF/services/example.Service", new FixtureEntry(
                "example.Implementation\n".getBytes(StandardCharsets.UTF_8), 1));
        result.put("assets/预设/测试.np3", new FixtureEntry(new byte[] {1, 2, 3, 4}, 1));
        result.put("assets/empty-deflated", new FixtureEntry(new byte[0], 1));
        result.put("assets/empty-stored", new FixtureEntry(new byte[0], 0));
        return result;
    }

    private Path writeArchive(String filename, Map<String, FixtureEntry> entries, boolean align)
            throws IOException {
        return writeArchive(filename, entries, align, 16_384);
    }

    private Path writeArchive(String filename, Map<String, FixtureEntry> entries, boolean align,
            long nativeAlignment) throws IOException {
        Path result = path(filename);
        try (ZipArchive archive = new ZipArchive(result)) {
            for (Map.Entry<String, FixtureEntry> entry : entries.entrySet()) {
                FixtureEntry contents = entry.getValue();
                BytesSource source = new BytesSource(contents.data, entry.getKey(), contents.level);
                if (align && contents.level == 0) {
                    source.align(entry.getKey().endsWith(".so") ? nativeAlignment : 4);
                }
                archive.add(source);
            }
        }
        return result;
    }

    private static byte[] readEntry(Path archive, String name) throws IOException {
        try (java.util.zip.ZipFile zip = new java.util.zip.ZipFile(archive.toFile());
                java.io.InputStream input = zip.getInputStream(zip.getEntry(name))) {
            return input.readAllBytes();
        }
    }

    private static byte[] compressedPayload(Path archive, String name) throws IOException {
        Entry entry = ZipMap.from(archive).getEntries().get(name);
        int start = Math.toIntExact(entry.getPayloadLocation().first);
        int end = Math.toIntExact(start + entry.getCompressedSize());
        return Arrays.copyOfRange(Files.readAllBytes(archive), start, end);
    }

    private static void replaceAscii(byte[] bytes, String from, String to) {
        byte[] needle = from.getBytes(StandardCharsets.US_ASCII);
        byte[] replacement = to.getBytes(StandardCharsets.US_ASCII);
        assertEquals(needle.length, replacement.length);
        int count = 0;
        for (int i = 0; i <= bytes.length - needle.length; i++) {
            if (Arrays.equals(bytes, i, i + needle.length, needle, 0, needle.length)) {
                System.arraycopy(replacement, 0, bytes, i, replacement.length);
                count++;
                i += needle.length - 1;
            }
        }
        assertEquals("Patch both the local header and central directory", 2, count);
    }

    private Path path(String name) {
        return temporaryFolder.getRoot().toPath().resolve(name);
    }

    private record FixtureEntry(byte[] data, int level) {}
}
