package com.ztransfer.build;

import com.android.apksig.ApkSigner;
import com.android.apksig.ApkVerifier;
import com.android.apksig.KeyConfig;
import com.android.apksig.apk.ApkUtils;
import com.android.zipflinger.Entry;
import com.android.zipflinger.Source;
import com.android.zipflinger.Zip64;
import com.android.zipflinger.ZipArchive;
import com.android.zipflinger.ZipMap;
import com.android.zipflinger.ZipSource;
import com.android.zipflinger.ZipWriter;
import ru.eustas.zopfli.Options;
import ru.eustas.zopfli.Zopfli;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.Key;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.zip.CRC32;
import java.util.zip.DataFormatException;
import java.util.zip.Inflater;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/** Build-host tool only. It changes ZIP compression, never Android application payloads. */
public final class ReleaseApkOptimizer {
    private static final int MIN_COMPRESSED_SIZE = 4096;
    private static final int BUFFER_SIZE = 64 * 1024;
    private static final Options OPTIONS = new Options(
            Options.OutputFormat.DEFLATE, Options.BlockSplitting.FIRST, 5);

    // Lazy allocation keeps signature/keystore failures cheap. Zopfli.compress is synchronized.
    private static final class Compressor {
        private static final Zopfli INSTANCE = new Zopfli(1024 * 1024);
    }

    private ReleaseApkOptimizer() {}

    public static void main(String[] args) {
        if (args.length != 3) {
            System.err.println("Usage: ReleaseApkOptimizer <input.apk> <output.apk> <project-root>");
            System.exit(2);
        }
        try {
            optimize(Path.of(args[0]), Path.of(args[1]), Path.of(args[2]));
        } catch (Exception error) {
            // Do not expose keystore exception chains or credentials in build logs.
            System.err.println("Release APK optimization failed: " + error.getMessage());
            System.exit(1);
        }
    }

    public static void optimize(Path input, Path output, Path projectRoot) throws Exception {
        input = input.toRealPath();
        output = output.toAbsolutePath().normalize();
        if (input.equals(output) || (Files.exists(output) && Files.isSameFile(input, output))) {
            throw new IOException("Input and output APK must be different files.");
        }
        // No re-signing of other schemes, rotated keys, stamps or multiple signers by accident.
        ApkVerifier.Result originalSignature = verifySignature(input);
        SigningKey key = readSigningKey(projectRoot);
        requireSameCertificate(originalSignature.getSignerCertificates().get(0), key.chain.get(0));
        Files.createDirectories(output.getParent());
        Path temporary = Files.createTempDirectory(output.getParent(), ".release-apk-");
        try {
            Path snapshot = temporary.resolve("original.apk");
            Files.copy(input, snapshot);
            ApkVerifier.Result snapshotSignature = verifySignature(snapshot);
            requireSameCertificate(snapshotSignature.getSignerCertificates().get(0), key.chain.get(0));
            Path unsigned = temporary.resolve("compressed.apk");
            Path signed = temporary.resolve("signed.apk");
            recompress(snapshot, unsigned);
            int minSdk;
            try (ZipFile zip = new ZipFile(snapshot.toFile())) {
                ZipEntry manifest = zip.getEntry("AndroidManifest.xml");
                if (manifest == null) throw new IOException("APK manifest is missing.");
                minSdk = ApkUtils.getMinSdkVersionFromBinaryAndroidManifest(
                        ByteBuffer.wrap(readEntry(zip, manifest)));
            }
            if (minSdk < 24) throw new IOException("V2-only optimization requires minSdk 24 or newer.");
            ApkSigner.SignerConfig signer = new ApkSigner.SignerConfig.Builder(
                    "release", new KeyConfig.Jca(key.privateKey), key.chain).build();
            new ApkSigner.Builder(List.of(signer))
                    .setInputApk(unsigned.toFile())
                    .setOutputApk(signed.toFile())
                    .setMinSdkVersion(minSdk)
                    .setV1SigningEnabled(false)
                    .setV2SigningEnabled(true)
                    .setV3SigningEnabled(false)
                    .setV4SigningEnabled(false)
                    .setOtherSignersSignaturesPreserved(false)
                    .setAlignmentPreserved(true)
                    .setLibraryPageAlignmentBytes(16 * 1024)
                    .build().sign();
            verifyEntries(snapshot, signed);
            ApkVerifier.Result result = verifySignature(signed);
            requireSameCertificate(snapshotSignature.getSignerCertificates().get(0),
                    result.getSignerCertificates().get(0));
            long before = Files.size(snapshot);
            long after = Files.size(signed);
            Path chosen = after < before ? signed : snapshot;
            // Even the no-saving fallback must meet the same payload and alignment checks.
            if (chosen.equals(snapshot)) verifyEntries(snapshot, snapshot);
            // Fail closed when atomic replacement is unavailable; never delete the previous output.
            Files.move(chosen, output, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            System.out.printf(Locale.ROOT, "Release APK verified: %,d -> %,d bytes; saved %,d bytes (%.2f%%).%n",
                    before, Files.size(output), before - Files.size(output),
                    100.0 * (before - Files.size(output)) / before);
        } finally {
            deleteTemporaryDirectory(temporary);
        }
    }

    static void recompress(Path input, Path output) throws IOException {
        if (Files.exists(output)) throw new IOException("Compressed APK output already exists.");
        Map<String, ZipEntry> entries = readEntries(input);
        ZipMap map = ZipMap.from(input, false, Zip64.Policy.FORBID);
        try (ZipFile original = new ZipFile(input.toFile());
             ZipArchive archive = new ZipArchive(output, Zip64.Policy.FORBID)) {
            for (ZipEntry entry : entries.values()) {
                ZipSource copy = new ZipSource(map);
                copy.select(entry.getName(), entry.getName(), ZipSource.COMPRESSION_NO_CHANGE,
                        alignment(entry));
                if (entry.getMethod() == ZipEntry.DEFLATED
                        && entry.getCompressedSize() > MIN_COMPRESSED_SIZE) {
                    byte[] raw = readEntry(original, entry);
                    byte[] compressed = compress(raw);
                    if (compressed.length < entry.getCompressedSize()) {
                        Source metadata = copy.getSelectedEntries().get(0);
                        archive.add(new DeflatedSource(entry, compressed, metadata));
                        continue;
                    }
                }
                archive.add(copy);
            }
        }
        verifyEntries(input, output);
    }

    static byte[] compress(byte[] input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Compressor.INSTANCE.compress(OPTIONS, input, output);
        byte[] compressed = output.toByteArray();
        // Verify raw DEFLATE framing independently of the compressor before it enters an APK.
        Inflater inflater = new Inflater(true);
        try {
            inflater.setInput(compressed);
            byte[] buffer = new byte[BUFFER_SIZE];
            int offset = 0;
            while (!inflater.finished()) {
                int count = inflater.inflate(buffer);
                if (count == 0 && !inflater.finished()) {
                    throw new IOException("Compressed payload cannot be decoded completely.");
                }
                if (offset + (long) count > input.length
                        || !Arrays.equals(buffer, 0, count, input, offset, offset + count)) {
                    throw new IOException("Compressed payload differs from its input.");
                }
                offset += count;
            }
            if (offset != input.length || inflater.getRemaining() != 0) {
                throw new IOException("Compressed payload length is invalid.");
            }
        } catch (DataFormatException error) {
            throw new IOException("Compressed payload is not valid raw DEFLATE.");
        } finally {
            inflater.end();
        }
        return compressed;
    }

    static void verifyEntries(Path original, Path candidate) throws IOException {
        Map<String, ZipEntry> expected = readEntries(original);
        Map<String, ZipEntry> actual = readEntries(candidate);
        if (!expected.keySet().equals(actual.keySet())) {
            throw new IOException("APK entry names changed.");
        }
        Map<String, Entry> positions = ZipMap.from(candidate, false, Zip64.Policy.FORBID).getEntries();
        try (ZipFile left = new ZipFile(original.toFile()); ZipFile right = new ZipFile(candidate.toFile())) {
            for (ZipEntry entry : expected.values()) {
                ZipEntry other = actual.get(entry.getName());
                if (entry.getMethod() != other.getMethod() || entry.getSize() != other.getSize()
                        || entry.getCrc() != other.getCrc()) {
                    throw new IOException("APK entry metadata changed: " + entry.getName());
                }
                long alignment = alignment(other);
                if (alignment > 1 && positions.get(entry.getName()).getPayloadLocation().first % alignment != 0) {
                    throw new IOException("APK entry is not aligned: " + entry.getName());
                }
                CRC32 crc = new CRC32();
                long length = 0;
                try (InputStream source = left.getInputStream(entry);
                     InputStream target = right.getInputStream(other)) {
                    while (true) {
                        byte[] a = source.readNBytes(BUFFER_SIZE);
                        byte[] b = target.readNBytes(BUFFER_SIZE);
                        if (!Arrays.equals(a, b)) throw new IOException("APK payload changed: " + entry.getName());
                        if (a.length == 0) break;
                        crc.update(a);
                        length += a.length;
                    }
                }
                if (length != entry.getSize() || crc.getValue() != entry.getCrc()) {
                    throw new IOException("APK payload checksum is invalid: " + entry.getName());
                }
            }
        }
    }

    private static Map<String, ZipEntry> readEntries(Path path) throws IOException {
        // ZipMap with FORBID catches ZIP64; ZipFile enumeration catches duplicate names that
        // a name-to-entry map would otherwise silently overwrite.
        ZipMap map = ZipMap.from(path, false, Zip64.Policy.FORBID);
        Map<String, ZipEntry> entries = new LinkedHashMap<>();
        try (ZipFile zip = new ZipFile(path.toFile())) {
            Enumeration<? extends ZipEntry> iterator = zip.entries();
            while (iterator.hasMoreElements()) {
                ZipEntry entry = iterator.nextElement();
                if (entries.put(entry.getName(), entry) != null) {
                    throw new IOException("Duplicate APK entry: " + entry.getName());
                }
                if (entry.getMethod() != ZipEntry.STORED && entry.getMethod() != ZipEntry.DEFLATED) {
                    throw new IOException("Unsupported APK compression method.");
                }
                if (entry.getSize() < 0 || entry.getCompressedSize() < 0 || entry.getCrc() < 0) {
                    throw new IOException("APK entry metadata is incomplete.");
                }
                if (entry.getName().equals("resources.arsc") && entry.getMethod() != ZipEntry.STORED) {
                    throw new IOException("resources.arsc must remain uncompressed.");
                }
            }
        }
        if (!entries.keySet().equals(map.getEntries().keySet())) {
            throw new IOException("APK ZIP directory is inconsistent.");
        }
        return entries;
    }

    private static byte[] readEntry(ZipFile zip, ZipEntry entry) throws IOException {
        if (entry.getSize() > Integer.MAX_VALUE - 8L) throw new IOException("APK entry is too large to optimize.");
        byte[] bytes;
        try (InputStream input = zip.getInputStream(entry)) {
            bytes = input.readNBytes((int) entry.getSize());
            if (bytes.length != entry.getSize() || input.read() != -1) {
                throw new IOException("APK entry length is invalid: " + entry.getName());
            }
        }
        CRC32 crc = new CRC32();
        crc.update(bytes);
        if (crc.getValue() != entry.getCrc()) throw new IOException("APK entry checksum is invalid: " + entry.getName());
        return bytes;
    }

    private static long alignment(ZipEntry entry) {
        if (entry.getMethod() != ZipEntry.STORED) return Source.NO_ALIGNMENT;
        return entry.getName().startsWith("lib/") && entry.getName().endsWith(".so") ? 16 * 1024 : 4;
    }

    private static ApkVerifier.Result verifySignature(Path apk) throws Exception {
        ApkVerifier.Result result = new ApkVerifier.Builder(apk.toFile()).build().verify();
        if (!result.isVerified() || !result.isVerifiedUsingV2Scheme()) {
            throw new IOException("APK signature verification failed.");
        }
        if (result.isVerifiedUsingV1Scheme() || result.isVerifiedUsingV3Scheme()
                || result.isVerifiedUsingV31Scheme() || result.isVerifiedUsingV4Scheme()
                || !result.getV1SchemeSigners().isEmpty() || !result.getV1SchemeIgnoredSigners().isEmpty()
                || !result.getV3SchemeSigners().isEmpty() || !result.getV31SchemeSigners().isEmpty()
                || !result.getV4SchemeSigners().isEmpty() || result.getSigningCertificateLineage() != null
                || result.getSourceStampInfo() != null || result.getSignerCertificates().size() != 1
                || result.getV2SchemeSigners().size() != 1
                || Files.exists(apk.resolveSibling(apk.getFileName() + ".idsig"))) {
            throw new IOException("Only a single-signer, V2-only APK without a stamp or key rotation is supported.");
        }
        for (String name : readEntries(apk).keySet()) {
            String upper = name.toUpperCase(Locale.ROOT);
            if (name.equals(ApkUtils.SOURCE_STAMP_CERTIFICATE_HASH_ZIP_ENTRY_NAME)
                    || (upper.startsWith("META-INF/") && (upper.endsWith(".SF")
                    || upper.endsWith(".RSA") || upper.endsWith(".DSA") || upper.endsWith(".EC")))) {
                throw new IOException("APK contains an unsupported signing scheme or source stamp.");
            }
        }
        return result;
    }

    private static SigningKey readSigningKey(Path root) throws IOException {
        Properties properties = new Properties();
        try (InputStream stream = Files.newInputStream(root.resolve("keystore.properties"))) {
            properties.load(stream);
        }
        char[] storePassword = required(properties, "storePassword").toCharArray();
        char[] keyPassword = required(properties, "keyPassword").toCharArray();
        try {
            Path keyFile = Path.of(required(properties, "storeFile"));
            if (!keyFile.isAbsolute()) keyFile = root.resolve("app").resolve(keyFile);
            KeyStore keyStore = KeyStore.getInstance(keyFile.toFile(), storePassword);
            String alias = required(properties, "keyAlias");
            Key key = keyStore.getKey(alias, keyPassword);
            if (!(key instanceof PrivateKey privateKey)) throw new IOException("Release key alias has no private key.");
            Certificate[] certificates = keyStore.getCertificateChain(alias);
            if (certificates == null || certificates.length == 0) throw new IOException("Release signing certificate is missing.");
            List<X509Certificate> chain = new ArrayList<>();
            for (Certificate certificate : certificates) chain.add((X509Certificate) certificate);
            return new SigningKey(privateKey, chain);
        } catch (Exception error) {
            throw new IOException("Unable to load the configured release signing key.");
        } finally {
            Arrays.fill(storePassword, '\0');
            Arrays.fill(keyPassword, '\0');
            properties.clear();
        }
    }

    private static String required(Properties properties, String name) throws IOException {
        String value = properties.getProperty(name);
        if (value == null) throw new IOException("Missing release signing property: " + name);
        return value;
    }

    private static void requireSameCertificate(X509Certificate a, X509Certificate b) throws Exception {
        if (!Arrays.equals(a.getEncoded(), b.getEncoded())) {
            throw new IOException("Release signing certificate does not match the original APK.");
        }
    }

    private static void deleteTemporaryDirectory(Path directory) throws IOException {
        try (var files = Files.walk(directory)) {
            for (Path path : files.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
        }
    }

    private record SigningKey(PrivateKey privateKey, List<X509Certificate> chain) {}

    private static final class DeflatedSource extends Source {
        private final byte[] bytes;

        private DeflatedSource(ZipEntry entry, byte[] bytes, Source metadata) {
            super(entry.getName());
            this.bytes = bytes;
            compressedSize = bytes.length;
            uncompressedSize = entry.getSize();
            crc = (int) entry.getCrc();
            compressionFlag = ZipEntry.DEFLATED;
            versionMadeBy = metadata.getVersionMadeBy();
            externalAttributes = metadata.getExternalAttributes();
        }

        @Override public void prepare() {}

        @Override public long writeTo(ZipWriter writer) throws IOException {
            ByteBuffer buffer = ByteBuffer.wrap(bytes);
            while (buffer.hasRemaining()) writer.write(buffer);
            return bytes.length;
        }
    }
}
