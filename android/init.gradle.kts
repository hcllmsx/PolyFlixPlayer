import org.gradle.api.artifacts.dsl.RepositoryHandler
import org.gradle.api.artifacts.repositories.MavenArtifactRepository

// 强制国内镜像直连，绕过全局 ~/.gradle/gradle.properties 中可能配置的本地代理 (127.0.0.1:10808)
val nonProxy = "localhost|127.*|[::1]|*.aliyun.com|maven.aliyun.com|*.flutter-io.cn|storage.flutter-io.cn"
System.setProperty("http.nonProxyHosts", nonProxy)
System.setProperty("https.nonProxyHosts", nonProxy)

val domesticMirrorUrls = listOf(
    "https://maven.aliyun.com/repository/gradle-plugin",
    "https://maven.aliyun.com/repository/google",
    "https://maven.aliyun.com/repository/central",
    "https://storage.flutter-io.cn/download.flutter.io",
)

fun RepositoryHandler.prependDomesticMirrors() {
    val existingUrls = mapNotNull { (it as? MavenArtifactRepository)?.url?.toString()?.trimEnd('/') }.toSet()
    val toAdd = domesticMirrorUrls.filter { it.trimEnd('/') !in existingUrls }
    for (mirrorUrl in toAdd) {
        maven {
            url = uri(mirrorUrl)
        }
    }
}

beforeSettings {
    pluginManagement.repositories.prependDomesticMirrors()
    @Suppress("UnstableApiUsage")
    dependencyResolutionManagement.repositories.prependDomesticMirrors()
}

beforeProject {
    buildscript.repositories.prependDomesticMirrors()
}
