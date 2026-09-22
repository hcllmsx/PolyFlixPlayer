allprojects {
    repositories {
        // 国内镜像（加速首次构建），原源作为兜底保留
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}
// 【历史与警告，勿删这段说明】
//
// 这里曾经有一段 `tasks.matching { it.name.contains("AarMetadata") }.enabled = false`
// （后来还配了"补空目录"的代码来绕过 Gradle 的输入校验）。它掩盖的是这样一个冲突：
//
//   ':ffmpeg_kit_flutter_new_min' requires ... compile against version 35 or later
//   ':whisper_ggml is currently compiled against android-34'
//
// 即 whisper_ggml 的 Android 模块写死 compileSdk 34，而它的依赖链上有要求 >= 35 的
// ffmpeg_kit_flutter_new_min。
//
// 该冲突已在 third_party/whisper_ggml/android/build.gradle 里通过把 compileSdk 抬到
// 36 根治，所以这段 hack 已经删除，AAR 元数据校验恢复由 AGP 正常执行。
//
// 千万不要再加回来：禁用 check<变体>AarMetadata 会让 bundle<变体>Aar 声明为输入目录的
//   intermediates/aar_metadata_check/<变体>/check<变体>AarMetadata
// 永远不被产出，于是只要 build\ 被 flutter clean 清过一次，此后所有 Android 构建都会以
//   property 'aarMetadataCheck' specifies directory '...' which doesn't exist
// 失败；而且清缓存、删 android\.gradle、停 Gradle 守护进程都救不回来。

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
