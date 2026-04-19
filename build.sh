#!/bin/bash
set -eu

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '[!] Missing required tool: %s\n' "$1" >&2
        return 1
    fi
}

need_file() {
    if [ ! -f "$1" ]; then
        printf '[!] Missing required file: %s\n' "$1" >&2
        return 1
    fi
}

CLANGXX="${CLANGXX:-clang++}"
JAVAC="${JAVAC:-javac}"
ZIPALIGN="${ZIPALIGN:-zipalign}"
APKSIGNER="${APKSIGNER:-apksigner}"
KEYTOOL="${KEYTOOL:-keytool}"
LOCAL_AAPT_BIN="/data/data/com.termux/files/home/BringYourOwnModel/.toolcache/aapt-extract/data/data/com.termux/files/usr/bin/aapt"
LOCAL_AAPT_LIB="/data/data/com.termux/files/home/BringYourOwnModel/.toolcache/aapt-extract/data/data/com.termux/files/usr/lib"
if [ -z "${AAPT:-}" ]; then
    if command -v aapt >/dev/null 2>&1; then
        AAPT="$(command -v aapt)"
    elif [ -x "$LOCAL_AAPT_BIN" ]; then
        AAPT="$LOCAL_AAPT_BIN"
    else
        AAPT="aapt"
    fi
else
    AAPT="${AAPT}"
fi
ANDROID_JAR="${ANDROID_JAR:-${PREFIX:-/data/data/com.termux/files/usr}/share/java/android.jar}"
JAVA_RELEASE="${JAVA_RELEASE:-8}"

if command -v d8 >/dev/null 2>&1; then
    DEXER="${DEXER:-d8}"
elif command -v dx >/dev/null 2>&1; then
    DEXER="${DEXER:-dx}"
else
    DEXER="${DEXER:-}"
fi

need_cmd "$CLANGXX"
need_cmd "$JAVAC"
need_cmd "$ZIPALIGN"
need_cmd "$APKSIGNER"
need_cmd "$KEYTOOL"
need_cmd "$AAPT"

if [ -z "$DEXER" ]; then
    printf '[!] Missing required tool: d8 or dx\n' >&2
    exit 127
fi
need_cmd "$DEXER"

need_file AndroidManifest.xml
need_file jni/native-lib.cpp
need_file src/com/amiraq/byom/MainActivity.java
need_file "$ANDROID_JAR"

run_aapt() {
    if [ "$AAPT" = "$LOCAL_AAPT_BIN" ] && [ -d "$LOCAL_AAPT_LIB" ]; then
        LD_LIBRARY_PATH="$LOCAL_AAPT_LIB:${LD_LIBRARY_PATH:-}" "$AAPT" "$@"
    else
        "$AAPT" "$@"
    fi
}

mkdir -p \
    bin \
    obj \
    src/com/amiraq/byom \
    libs/arm64-v8a \
    bin/apk-root/lib/arm64-v8a

printf '=> [1] Compiling C++ Bridge (JNI)...\n'
"$CLANGXX" \
    -shared \
    -fPIC \
    -o libs/arm64-v8a/libllama_engine.so \
    jni/native-lib.cpp \
    -llog

printf '=> [2] Packaging Resources & Generating R.java...\n'
run_aapt package \
    -f \
    -m \
    -J src \
    -M AndroidManifest.xml \
    -S res \
    -I "$ANDROID_JAR"

printf '=> [3] Compiling Java Sources...\n'
"$JAVAC" \
    -d obj \
    --release "$JAVA_RELEASE" \
    -classpath "$ANDROID_JAR" \
    -sourcepath src \
    src/com/amiraq/byom/*.java

printf '=> [4] Converting to Dalvik Executable (DEX)...\n'
if [ "$DEXER" = "d8" ] || [ "${DEXER##*/}" = "d8" ]; then
    rm -f bin/classes.dex
    "$DEXER" \
        --classpath "$ANDROID_JAR" \
        --output bin \
        obj/com/amiraq/byom/*.class
else
    "$DEXER" \
        --dex \
        --output=bin/classes.dex \
        obj/
fi

printf '=> [5] Assembling the Unsigned APK...\n'
run_aapt package \
    -f \
    -M AndroidManifest.xml \
    -S res \
    -I "$ANDROID_JAR" \
    -F bin/app-unsigned.apk

run_aapt add bin/app-unsigned.apk bin/classes.dex

printf '=> [6] Injecting C++ Native Engine...\n'
cp libs/arm64-v8a/libllama_engine.so bin/apk-root/lib/arm64-v8a/libllama_engine.so
run_aapt add bin/app-unsigned.apk bin/apk-root/lib/arm64-v8a/libllama_engine.so

printf '=> [7] Aligning APK Architecture...\n'
"$ZIPALIGN" -p -f 4 bin/app-unsigned.apk bin/app-aligned.apk

printf '=> [8] Cryptographic Signing...\n'
if [ ! -f key.jks ]; then
    printf 'Generating new Keystore...\n'
    "$KEYTOOL" \
        -genkeypair \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=Ammar, O=Amiraq, C=IQ" \
        -keystore key.jks \
        -storepass 12345678 \
        -keypass 12345678
fi

"$APKSIGNER" sign --ks key.jks --ks-pass pass:12345678 bin/app-aligned.apk

printf '==========================================\n'
printf '[+] SUCCESS! App Built at: bin/app-aligned.apk\n'
printf "[+] Type: 'termux-open bin/app-aligned.apk' to install.\n"
printf '==========================================\n'
