#!/usr/bin/env bash
# Compile the Android bridge against cached SDKs, then run its pure-JVM checks.
# This does not build an APK or emulate Android's PAC service.
set -euo pipefail
proxy_project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
proxy_build_root="${AIPLAYER_BUILD_ROOT:-$proxy_project_root/.local-build}"
proxy_compiler="$(rg --files "$proxy_build_root/cache/gradle/wrapper/dists" -g 'kotlin-compiler-embeddable-*.jar' | sort -V | tail -n 1)"
proxy_kotlin_lib="$(dirname -- "$proxy_compiler")"
proxy_android_jar="$(rg --files "$proxy_build_root/sdk/android/platforms" -g android.jar | sort -V | tail -n 1)"
proxy_lifecycle_jar="$(rg --files "$proxy_build_root/cache/gradle/caches/modules-2/files-2.1/androidx.lifecycle/lifecycle-common-jvm" -g '*.jar' | sort -V | tail -n 1)"
proxy_flutter_jar="$proxy_build_root/sdk/flutter/bin/cache/artifacts/engine/android-arm64/flutter.jar"
proxy_stdlib=("$proxy_kotlin_lib"/kotlin-stdlib-*.jar)
for proxy_required in "$proxy_compiler" "$proxy_android_jar" "$proxy_lifecycle_jar" "$proxy_flutter_jar" "${proxy_stdlib[0]}"; do
  if [[ ! -f "$proxy_required" ]]; then
    echo 'Missing cached Android/Kotlin/Flutter build dependency.' >&2
    exit 1
  fi
done
mkdir -p "$proxy_build_root/tmp"
proxy_output="$(mktemp -d "$proxy_build_root/tmp/system-proxy-check.XXXXXX")"
trap 'rm -rf -- "$proxy_output"' EXIT
proxy_sources="$proxy_project_root/client/android/app/src/main/kotlin/app/aiplayer/aiplayer"
java -cp "$proxy_kotlin_lib/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -jvm-target 17 \
  -classpath "$proxy_android_jar:$proxy_flutter_jar:$proxy_lifecycle_jar:${proxy_stdlib[0]}" \
  -d "$proxy_output" \
  "$proxy_sources/SystemProxyResolver.kt" \
  "$proxy_sources/SystemProxyHandler.kt" \
  "$proxy_sources/MainActivity.kt" \
  "$proxy_sources/ExternalVideoHandler.kt" \
  "$proxy_project_root/client/android/host_test/SystemProxyResolverCheck.kt"
java -cp "$proxy_output:${proxy_stdlib[0]}" app.aiplayer.aiplayer.SystemProxyResolverCheckKt
