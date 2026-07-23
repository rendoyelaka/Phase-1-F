import org.gradle.api.Plugin
import org.gradle.api.Project
import java.security.SecureRandom

class ResRenamerPlugin implements Plugin<Project> {

    private static final Set<String> KEEP_NAMES = [
        'ic_launcher',
        'ic_launcher_round',
        'ic_launcher_background',
        'ic_launcher_foreground',
        'ic_launcher_notification'
    ] as Set

    private static final Set<String> RENAMEABLE_DIRS = [
        'drawable',
        'layout'
    ] as Set

    @Override
    void apply(Project project) {
        project.plugins.withId('com.android.application') {
            project.android.applicationVariants.all { variant ->
                if (variant.buildType.name != 'release') return

                def mergeTask   = project.tasks.findByName('mergeReleaseResources')
                def processTask = project.tasks.findByName('processReleaseResources')

                if (!mergeTask) {
                    project.logger.warn('[ResRenamerPlugin] mergeReleaseResources not found - skipping')
                    return
                }

                def renameTask = project.tasks.register('renameReleaseResFiles') {
                    description = 'Randomise res filenames for release build'
                    group = 'build'
                    dependsOn mergeTask
                    if (processTask) processTask.dependsOn it

                    doLast {
                        def rng = new SecureRandom()

                        def mergedRes = new File("${project.buildDir}/intermediates/merged_res/release")
                        if (!mergedRes.exists()) {
                            mergedRes = new File("${project.buildDir}/intermediates/res/merged/release")
                        }
                        if (!mergedRes.exists()) {
                            project.logger.warn('[ResRenamerPlugin] Merged res dir not found - skipping rename')
                            return
                        }

                        def usedNames = new HashSet<String>()
                        int renamed = 0

                        mergedRes.eachFileRecurse { file ->
                            if (!file.isFile()) return

                            def parentName = file.parentFile.name
                            def dirBase = RENAMEABLE_DIRS.find { parentName.startsWith(it) }
                            if (!dirBase) return

                            def baseName = file.name.contains('.') ? file.name.substring(0, file.name.lastIndexOf('.')) : file.name
                            def ext = file.name.contains('.') ? file.name.substring(file.name.lastIndexOf('.')) : ''

                            if (KEEP_NAMES.any { baseName.startsWith(it) }) return

                            def newBase
                            int attempts = 0
                            do {
                                newBase = randomName(rng, 2 + rng.nextInt(2))
                                attempts++
                                if (attempts > 500) {
                                    project.logger.warn("[ResRenamerPlugin] Could not find unique name for ${file.name}")
                                    return
                                }
                            } while (usedNames.contains(newBase + ext))

                            usedNames.add(newBase + ext)
                            def newFile = new File(file.parentFile, newBase + ext)
                            file.renameTo(newFile)
                            project.logger.lifecycle("[ResRenamerPlugin] Renamed: ${file.name} -> ${newBase + ext}")
                            renamed++
                        }

                        project.logger.lifecycle("[ResRenamerPlugin] Total renamed: ${renamed}")
                    }
                }
            }
        }
    }

    private static String randomName(SecureRandom rng, int len) {
        def chars = (('a'..'z') + ('A'..'Z')).toList()
        (1..len).collect { chars[rng.nextInt(chars.size())] }.join('')
    }
}
