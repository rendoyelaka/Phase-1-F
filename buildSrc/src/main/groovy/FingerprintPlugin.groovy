import org.gradle.api.Plugin
import org.gradle.api.Project
import java.security.SecureRandom
import javax.crypto.KeyGenerator

class FingerprintPlugin implements Plugin<Project> {

    @Override
    void apply(Project project) {
        // Generate synchronously at plugin apply time (configuration phase)
        // so project.ext values are available when build.gradle reads them
        // for buildConfigField — same pattern as KeystoreGeneratorPlugin.
        // afterEvaluate is too late: AGP locks buildConfigFields before it runs.

        def outputDir = new File(project.buildDir, 'fingerprint')
        outputDir.mkdirs()

        def rng = new SecureRandom()

        def buildUUID      = UUID.randomUUID().toString()
        def saltBytes      = new byte[32]; rng.nextBytes(saltBytes)
        def saltHex        = bytesToHex(saltBytes)
        def keyGen         = KeyGenerator.getInstance("AES"); keyGen.init(256, rng)
        def aesKeyHex      = bytesToHex(keyGen.generateKey().encoded)
        def ivBytes        = new byte[16]; rng.nextBytes(ivBytes)
        def aesIvHex       = bytesToHex(ivBytes)
        def buildTimestamp = new Date().format("yyyyMMdd_HHmmss_SSS")
        def token          = (buildUUID + saltHex + buildTimestamp).bytes

        // Expose via project.ext — build.gradle reads these inline at config time
        project.ext.fp_buildUUID      = buildUUID
        project.ext.fp_saltHex        = saltHex
        project.ext.fp_aesKeyHex      = aesKeyHex
        project.ext.fp_aesIvHex       = aesIvHex
        project.ext.fp_buildTimestamp = buildTimestamp
        project.ext.fp_md5            = hashBytes(token, "MD5")
        project.ext.fp_sha1           = hashBytes(token, "SHA-1")
        project.ext.fp_sha256         = hashBytes(token, "SHA-256")
        project.ext.fp_sha512         = hashBytes(token, "SHA-512")

        project.logger.lifecycle("[FingerprintPlugin] ✅ Fingerprint: ${buildUUID} | ${buildTimestamp}")

        // Wipe temp props file after build if written
        project.gradle.buildFinished {
            outputDir.listFiles()?.each { f ->
                if (f.name.startsWith("fingerprint_") && f.name.endsWith(".properties")) {
                    f.delete()
                    project.logger.lifecycle("[FingerprintPlugin] 🗑️  Wiped: ${f.name}")
                }
            }
        }
    }

    static String bytesToHex(byte[] bytes) {
        bytes.collect { String.format('%02x', it & 0xff) }.join('')
    }
    static String hashBytes(byte[] data, String algo) {
        bytesToHex(java.security.MessageDigest.getInstance(algo).digest(data))
    }
}

class FingerprintExtension {
    File   outputDir
    String label
}
