// All Maven traffic is routed through the local caching proxy
// (http://127.0.0.1:18080, see ~/workspace/tools/maven-proxy/) because
// Gradle's Java HTTP client stalls on direct TLS downloads through the
// egress MITM proxy. The proxy fetches from the real repos (Maven Central,
// Google, Chaquopy) with curl and caches them locally.
allprojects {
    repositories {
        maven { url = uri("http://127.0.0.1:18080/maven2") }
        maven { url = uri("http://127.0.0.1:18080/chaquo") }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
