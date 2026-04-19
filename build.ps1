[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Run,
    [switch]$Clean,
    [string]$AvdName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$SdkRootCandidates = @(
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME,
    (Join-Path $env:LOCALAPPDATA "Android\Sdk"),
    "C:\Android\Sdk"
) | Where-Object { $_ }

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    foreach ($candidate in $Candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Unable to locate $Label."
}

function Resolve-CommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string[]]$Fallbacks = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($fallback in $Fallbacks) {
        if (Test-Path $fallback) {
            return (Resolve-Path $fallback).Path
        }
    }

    throw "Unable to locate required command '$Name'."
}

function Get-LatestDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        throw "Unable to locate $Label."
    }

    $directory = Get-ChildItem $Path -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $directory) {
        throw "Unable to locate $Label."
    }

    return $directory.FullName
}

function Remove-IfExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host "=> $Message"
    & $Action
}

function Wait-ForPackageService {
    param([Parameter(Mandatory = $true)][string]$AdbPath)

    & $AdbPath wait-for-device | Out-Null
    for ($i = 0; $i -lt 120; $i++) {
        $bootCompleted = (& $AdbPath shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        $packageService = (& $AdbPath shell service check package 2>$null | Out-String)
        if ($bootCompleted -eq "1" -and $packageService -match "found") {
            return
        }
        Start-Sleep -Seconds 5
    }

    throw "Connected device did not become ready in time."
}

function Get-AvailableAvdNames {
    param([Parameter(Mandatory = $true)][string]$EmulatorPath)

    if (-not (Test-Path $EmulatorPath)) {
        return @()
    }

    return @((& $EmulatorPath -list-avds 2>$null | Where-Object { $_ -and $_.Trim() -ne "" }))
}

function Ensure-DeviceReady {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [string]$EmulatorPath,
        [string]$AvdName
    )

    $deviceList = & $AdbPath devices
    if ($deviceList -notmatch "device$") {
        if (-not $EmulatorPath) {
            throw "No emulator executable was found."
        }

        if (-not $AvdName) {
            $availableAvds = @(Get-AvailableAvdNames -EmulatorPath $EmulatorPath)
            if ($availableAvds.Count -eq 1) {
                $AvdName = $availableAvds[0]
            }
            elseif ($availableAvds.Count -gt 1) {
                throw "Multiple AVDs are available. Pass -AvdName to choose one."
            }
            else {
                throw "No Android device detected. Connect a device or create an AVD."
            }
        }

        Start-Process -FilePath $EmulatorPath -ArgumentList @("-avd", $AvdName, "-no-snapshot-save", "-no-boot-anim") | Out-Null
    }

    Wait-ForPackageService -AdbPath $AdbPath
}

function Build-NativeAbi {
    param(
        [Parameter(Mandatory = $true)][string]$Abi,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$ToolchainFile,
        [Parameter(Mandatory = $true)][string]$CmakePath,
        [Parameter(Mandatory = $true)][string]$NinjaPath
    )

    & $CmakePath -S (Join-Path $Root "jni") -B $BuildDir -G Ninja `
        "-DCMAKE_MAKE_PROGRAM=$NinjaPath" `
        "-DCMAKE_TOOLCHAIN_FILE=$ToolchainFile" `
        "-DANDROID_ABI=$Abi" `
        "-DANDROID_PLATFORM=android-26" `
        "-DANDROID_STL=c++_shared" `
        "-DCMAKE_BUILD_TYPE=Release"
    if ($LASTEXITCODE -ne 0) {
        throw "CMake configure failed for ABI '$Abi'."
    }

    & $CmakePath --build $BuildDir --config Release -j 2
    if ($LASTEXITCODE -ne 0) {
        throw "CMake build failed for ABI '$Abi'."
    }
}

function Copy-RuntimeLibs {
    param(
        [Parameter(Mandatory = $true)][string]$Abi,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$AbiLibDir,
        [Parameter(Mandatory = $true)][string]$NdkRoot,
        [Parameter(Mandatory = $true)][string]$ClangLibRoot
    )

    $abiMap = @{
        "arm64-v8a" = @{
            RuntimeArch = "aarch64-linux-android"
            OmpArch     = "aarch64"
        }
        "x86_64" = @{
            RuntimeArch = "x86_64-linux-android"
            OmpArch     = "x86_64"
        }
    }

    $runtimeArch = $abiMap[$Abi].RuntimeArch
    $ompArch = $abiMap[$Abi].OmpArch

    Copy-Item (Join-Path $BuildDir "libllama_engine.so") (Join-Path $AbiLibDir "libllama_engine.so") -Force
    Copy-Item (Join-Path $NdkRoot "toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\$runtimeArch\libc++_shared.so") `
        (Join-Path $AbiLibDir "libc++_shared.so") -Force
    Copy-Item (Join-Path $ClangLibRoot "lib\linux\$ompArch\libomp.so") (Join-Path $AbiLibDir "libomp.so") -Force
}

if ($Run) {
    $Install = $true
}

$SdkRoot = Resolve-ExistingPath -Candidates $SdkRootCandidates -Label "Android SDK"
$NdkRoot = Get-LatestDirectory -Path (Join-Path $SdkRoot "ndk") -Label "Android NDK"
$BuildToolsRoot = Get-LatestDirectory -Path (Join-Path $SdkRoot "build-tools") -Label "Android build-tools"
$PlatformRoot = Get-LatestDirectory -Path (Join-Path $SdkRoot "platforms") -Label "Android platform"
$ClangLibRoot = Get-LatestDirectory -Path (Join-Path $NdkRoot "toolchains\llvm\prebuilt\windows-x86_64\lib\clang") -Label "NDK clang runtime"

$CmakePath = Resolve-CommandPath -Name "cmake" -Fallbacks @("C:\Program Files\CMake\bin\cmake.exe")
$NinjaPath = Resolve-CommandPath -Name "ninja" -Fallbacks @()
$JavacPath = Resolve-CommandPath -Name "javac" -Fallbacks @(
    "C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot\bin\javac.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-17.0.18.8-hotspot\bin\javac.exe"
)
$KeytoolPath = Resolve-CommandPath -Name "keytool" -Fallbacks @(
    "C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot\bin\keytool.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-17.0.18.8-hotspot\bin\keytool.exe"
)

$AaptPath = Join-Path $BuildToolsRoot "aapt.exe"
$D8Path = Join-Path $BuildToolsRoot "d8.bat"
$ZipalignPath = Join-Path $BuildToolsRoot "zipalign.exe"
$ApkSignerPath = Join-Path $BuildToolsRoot "apksigner.bat"
$AdbPath = Join-Path $SdkRoot "platform-tools\adb.exe"
$EmulatorPath = Join-Path $SdkRoot "emulator\emulator.exe"
$AndroidJar = Join-Path $PlatformRoot "android.jar"
$ToolchainFile = Join-Path $NdkRoot "build\cmake\android.toolchain.cmake"
$SourceTreeCheck = Join-Path $Root "jni\llama.cpp\CMakeLists.txt"

if (-not (Test-Path $SourceTreeCheck)) {
    throw "Missing llama.cpp sources at '$SourceTreeCheck'. Populate jni/llama.cpp before building."
}

foreach ($requiredPath in @($AaptPath, $D8Path, $ZipalignPath, $ApkSignerPath, $AndroidJar, $ToolchainFile, $NinjaPath)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Missing required dependency: $requiredPath"
    }
}

$BuildDirs = @{
    "arm64-v8a" = Join-Path $Root "jni\build-android"
    "x86_64"    = Join-Path $Root "jni\build-android-x86_64"
}

$OutRoot = Join-Path $Root "out"
$ApkRoot = Join-Path $OutRoot "apk"
$GenDir = Join-Path $ApkRoot "gen"
$ObjDir = Join-Path $ApkRoot "obj"
$BinDir = Join-Path $ApkRoot "bin"
$LibRoot = Join-Path $ApkRoot "lib"
$UnsignedApk = Join-Path $BinDir "app-unsigned.apk"
$AlignedApk = Join-Path $BinDir "app-aligned.apk"
$KeystorePath = Join-Path $Root "key.jks"

if ($Clean) {
    Invoke-Step "Cleaning previous native/output directories..." {
        Remove-IfExists -Path $OutRoot
        foreach ($buildDir in $BuildDirs.Values) {
            Remove-IfExists -Path $buildDir
        }
    }
}
else {
    Remove-IfExists -Path $OutRoot
}

Invoke-Step "Compiling JNI engine for arm64-v8a and x86_64..." {
    foreach ($entry in $BuildDirs.GetEnumerator()) {
        Build-NativeAbi -Abi $entry.Key -BuildDir $entry.Value -ToolchainFile $ToolchainFile -CmakePath $CmakePath -NinjaPath $NinjaPath
    }
}

Invoke-Step "Preparing APK workspace..." {
    foreach ($path in @($GenDir, $ObjDir, $BinDir, (Join-Path $LibRoot "arm64-v8a"), (Join-Path $LibRoot "x86_64"))) {
        Ensure-Directory -Path $path
    }

    Copy-RuntimeLibs -Abi "arm64-v8a" -BuildDir $BuildDirs["arm64-v8a"] -AbiLibDir (Join-Path $LibRoot "arm64-v8a") -NdkRoot $NdkRoot -ClangLibRoot $ClangLibRoot
    Copy-RuntimeLibs -Abi "x86_64" -BuildDir $BuildDirs["x86_64"] -AbiLibDir (Join-Path $LibRoot "x86_64") -NdkRoot $NdkRoot -ClangLibRoot $ClangLibRoot
}

Invoke-Step "Generating R.java..." {
    & $AaptPath package -f -m -J $GenDir -M (Join-Path $Root "AndroidManifest.xml") -S (Join-Path $Root "res") -I $AndroidJar
    if ($LASTEXITCODE -ne 0) {
        throw "aapt resource generation failed."
    }
}

Invoke-Step "Compiling Java sources..." {
    $javaSources = @(
        (Join-Path $Root "src\com\amiraq\byom\MainActivity.java"),
        (Join-Path $GenDir "com\amiraq\byom\R.java")
    )

    & $JavacPath --release 8 -d $ObjDir -classpath $AndroidJar $javaSources
    if ($LASTEXITCODE -ne 0) {
        throw "javac compilation failed."
    }
}

Invoke-Step "Building classes.dex..." {
    $classFiles = Get-ChildItem $ObjDir -Recurse -Filter *.class | Select-Object -ExpandProperty FullName
    & $D8Path --lib $AndroidJar --output $BinDir $classFiles
    if ($LASTEXITCODE -ne 0) {
        throw "d8 dex conversion failed."
    }
}

Invoke-Step "Packaging unsigned APK..." {
    & $AaptPath package -f -M (Join-Path $Root "AndroidManifest.xml") -S (Join-Path $Root "res") -I $AndroidJar -F $UnsignedApk
    if ($LASTEXITCODE -ne 0) {
        throw "aapt package failed."
    }

    Push-Location $BinDir
    try {
        & $AaptPath add "app-unsigned.apk" "classes.dex"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add classes.dex to APK."
        }
    }
    finally {
        Pop-Location
    }

    Push-Location $ApkRoot
    try {
        & $AaptPath add $UnsignedApk `
            "lib/arm64-v8a/libllama_engine.so" `
            "lib/arm64-v8a/libc++_shared.so" `
            "lib/arm64-v8a/libomp.so" `
            "lib/x86_64/libllama_engine.so" `
            "lib/x86_64/libc++_shared.so" `
            "lib/x86_64/libomp.so"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to inject native libraries into APK."
        }
    }
    finally {
        Pop-Location
    }
}

Invoke-Step "Aligning APK..." {
    & $ZipalignPath -p -f -v 4 $UnsignedApk $AlignedApk
    if ($LASTEXITCODE -ne 0) {
        throw "zipalign failed."
    }
}

Invoke-Step "Signing APK..." {
    if (-not (Test-Path $KeystorePath)) {
        & $KeytoolPath -genkeypair -validity 10000 -dname "CN=Ammar, O=Amiraq, C=IQ" `
            -keyalg RSA -keysize 2048 -keystore $KeystorePath -storepass 12345678 -keypass 12345678 -alias byom
        if ($LASTEXITCODE -ne 0) {
            throw "keytool failed to create keystore."
        }
    }

    & $ApkSignerPath sign --ks $KeystorePath --ks-key-alias byom --ks-pass pass:12345678 --key-pass pass:12345678 $AlignedApk
    if ($LASTEXITCODE -ne 0) {
        throw "apksigner failed."
    }
}

if ($Install) {
    Invoke-Step "Installing APK..." {
        $emulatorPathToUse = if (Test-Path $EmulatorPath) { $EmulatorPath } else { $null }
        Ensure-DeviceReady -AdbPath $AdbPath -EmulatorPath $emulatorPathToUse -AvdName $AvdName
        & $AdbPath install -r $AlignedApk
        if ($LASTEXITCODE -ne 0) {
            throw "adb install failed."
        }
    }
}

if ($Run) {
    Invoke-Step "Launching MainActivity..." {
        & $AdbPath shell am start -n "com.amiraq.byom/.MainActivity"
        if ($LASTEXITCODE -ne 0) {
            throw "adb launch failed."
        }
    }
}

Write-Host ""
Write-Host "APK ready at: $AlignedApk"
