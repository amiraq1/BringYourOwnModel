#!/bin/bash
set -eu

echo "=> [1] Compiling C++ Core Engine via CMake..."
mkdir -p jni/build && cd jni/build
cmake ..
# استخدام -j2 لمنع الاختناق الحراري للهاتف أثناء الترجمة
make -j2
cd ../../
# نقل المكتبة المجمعة إلى المسار الذي يتوقعه نظام Android
mkdir -p libs/arm64-v8a
cp jni/build/libllama_engine.so libs/arm64-v8a/

echo "=> [2] Packaging Resources & Generating R.java..."
$PREFIX/bin/aapt package -f -m -J src -M AndroidManifest.xml -S res -I $PREFIX/share/java/android.jar

echo "=> [3] Compiling Java Sources..."
javac -release 8 -d obj -classpath $PREFIX/share/java/android.jar -sourcepath src src/com/amiraq/byom/*.java

echo "=> [4] Converting to Dalvik Executable (DEX)..."
if command -v d8 >/dev/null 2>&1; then
    d8 --output=bin/ obj/com/amiraq/byom/*.class
else
    dx --dex --output=bin/classes.dex obj/
fi

echo "=> [5] Assembling the Unsigned APK..."
$PREFIX/bin/aapt package -f -M AndroidManifest.xml -S res -I $PREFIX/share/java/android.jar -F bin/app-unsigned.apk
cd bin
$PREFIX/bin/aapt add app-unsigned.apk classes.dex
cd ..

echo "=> [6] Injecting C++ Native Engine..."
cp -r libs lib
$PREFIX/bin/aapt add bin/app-unsigned.apk lib/arm64-v8a/libllama_engine.so
rm -rf lib

echo "=> [7] Aligning APK Architecture..."
$PREFIX/bin/zipalign -p -f -v 4 bin/app-unsigned.apk bin/app-aligned.apk

echo "=> [8] Cryptographic Signing..."
if [ ! -f key.jks ]; then
    echo "Generating Keystore..."
    keytool -genkeypair -validity 10000 -dname "CN=Ammar, O=Amiraq, C=IQ" -keyalg RSA -keysize 2048 -keystore key.jks -storepass 12345678 -keypass 12345678
fi
apksigner sign --ks key.jks --ks-pass pass:12345678 bin/app-aligned.apk

echo "=========================================="
echo "[+] SUCCESS! App Built at: bin/app-aligned.apk"
echo "=========================================="
