param([Parameter(Mandatory = $true)][string]$Device)
# Run on an x86_64 HarmonyOS emulator; Device is its hdc serial.
$ErrorActionPreference = 'Stop'
$tlsProjectRoot = Split-Path -Parent $PSScriptRoot
$tlsTestRoot = Join-Path $tlsProjectRoot '.hvigor/tls-regression'
$tlsSdkRoot = if ($env:OHOS_SDK_HOME) { $env:OHOS_SDK_HOME } else {
    Join-Path $env:ProgramFiles 'Huawei/DevEco Studio/sdk/default/openharmony'
}
$tlsOpenSsl = Join-Path $env:ProgramFiles 'Git/usr/bin/openssl.exe'
$tlsCompiler = Join-Path $tlsSdkRoot 'native/llvm/bin/clang++.exe'
$tlsHdc = Join-Path $tlsSdkRoot 'toolchains/hdc.exe'
$tlsObjRoot = Join-Path $tlsProjectRoot 'entry/build/default/intermediates/cmake/default/obj/x86_64'
New-Item -ItemType Directory -Path $tlsTestRoot -Force | Out-Null

function Invoke-TlsTool([string]$toolPath, [string[]]$toolArguments) {
    $toolResult = & $toolPath @toolArguments
    $toolExitCode = $LASTEXITCODE
    $toolResult | Write-Output
    if ($toolExitCode -ne 0 -or ($toolResult -join "`n") -match '\[Fail\]') {
        throw "TLS regression tool failed: $toolPath (exit $toolExitCode)"
    }
}

# All keys here are disposable test fixtures, unrelated to application profiles.
foreach ($authority in @('ca', 'other-ca')) {
    Invoke-TlsTool $tlsOpenSsl @('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2',
        '-subj', "/CN=Disposable TLS test $authority", '-addext', 'basicConstraints=critical,CA:TRUE',
        '-keyout', (Join-Path $tlsTestRoot "$authority.key"), '-out', (Join-Path $tlsTestRoot "$authority.crt"))
}
foreach ($identity in @('server', 'client')) {
    $tlsCommonName = if ($identity -eq 'server') { 'vpn.test' } else { 'client.test' }
    $tlsUsage = if ($identity -eq 'server') { 'serverAuth' } else { 'clientAuth' }
    @('basicConstraints=critical,CA:FALSE', 'keyUsage=critical,digitalSignature,keyEncipherment',
        "extendedKeyUsage=$tlsUsage", "subjectAltName=DNS:$tlsCommonName") |
        Set-Content -LiteralPath (Join-Path $tlsTestRoot "$identity.ext") -Encoding ascii
    Invoke-TlsTool $tlsOpenSsl @('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256',
        '-subj', "/CN=$tlsCommonName", '-keyout', (Join-Path $tlsTestRoot "$identity.key"),
        '-out', (Join-Path $tlsTestRoot "$identity.csr"))
    Invoke-TlsTool $tlsOpenSsl @('x509', '-req', '-in', (Join-Path $tlsTestRoot "$identity.csr"),
        '-CA', (Join-Path $tlsTestRoot 'ca.crt'), '-CAkey', (Join-Path $tlsTestRoot 'ca.key'),
        '-CAcreateserial', '-days', '2', '-sha256', '-extfile', (Join-Path $tlsTestRoot "$identity.ext"),
        '-out', (Join-Path $tlsTestRoot "$identity.crt"))
}

$tlsOriginalHeaders = Join-Path $tlsTestRoot 'original/openvpn/mbedtls/ssl'
New-Item -ItemType Directory -Path $tlsOriginalHeaders -Force | Out-Null
$tlsOriginalSource = git -C (Join-Path $tlsProjectRoot 'third_party/openvpn3') show HEAD:openvpn/mbedtls/ssl/sslctx.hpp
if ($LASTEXITCODE -ne 0) { throw 'Could not load the pinned original TLS implementation.' }
$tlsOriginalSource | Set-Content -LiteralPath (Join-Path $tlsOriginalHeaders 'sslctx.hpp') -Encoding utf8
$tlsCompileOptions = @('--target=x86_64-linux-ohos', "--sysroot=$(Join-Path $tlsSdkRoot 'native/sysroot')",
    '-std=c++17', '-O1', '-fexceptions', '-frtti',
    '-DUSE_MBEDTLS', '-DUSE_ASIO', '-DASIO_STANDALONE', '-D__MUSL__',
    "-I$(Join-Path $tlsProjectRoot 'third_party/openvpn3')", "-I$(Join-Path $tlsProjectRoot 'third_party/mbedtls/include')",
    "-I$(Join-Path $tlsProjectRoot 'third_party/asio/asio/include')", (Join-Path $tlsProjectRoot 'tests/native/tls_policy_test.cpp'))
$tlsLibraries = @('mbedtls', 'mbedx509', 'mbedcrypto', 'everest', 'p256m') |
    ForEach-Object { Join-Path $tlsObjRoot "lib$_.a" }
foreach ($variant in @('original', 'patched')) {
    [string[]]$tlsVariantOptions = @()
    if ($variant -eq 'original') { $tlsVariantOptions = @("-I$(Join-Path $tlsTestRoot 'original')") }
    Invoke-TlsTool $tlsCompiler ($tlsVariantOptions + $tlsCompileOptions + $tlsLibraries +
        @('-o', (Join-Path $tlsTestRoot "tls-$variant")))
}

$tlsRemoteRoot = '/data/local/tmp/shuangsecai-tls-regression'
Invoke-TlsTool $tlsHdc @('-t', $Device, 'shell', 'mkdir', '-p', $tlsRemoteRoot)
$tlsTransferFiles = @('ca.crt', 'other-ca.crt', 'server.crt', 'server.key', 'client.crt', 'client.key', 'tls-original', 'tls-patched')
foreach ($testFile in $tlsTransferFiles) {
    Invoke-TlsTool $tlsHdc @('-t', $Device, 'file', 'send', (Join-Path $tlsTestRoot $testFile), "$tlsRemoteRoot/$testFile")
}
Invoke-TlsTool $tlsHdc @('-t', $Device, 'file', 'send', (Join-Path $tlsObjRoot 'libc++_shared.so'), "$tlsRemoteRoot/libc++_shared.so")
Invoke-TlsTool $tlsHdc @('-t', $Device, 'shell', 'chmod', '700', "$tlsRemoteRoot/tls-original", "$tlsRemoteRoot/tls-patched")
foreach ($variant in @('original', 'patched')) {
    $tlsMode = if ($variant -eq 'original') { 'unpatched' } else { 'patched' }
    $tlsResult = & $tlsHdc -t $Device shell "LD_LIBRARY_PATH=$tlsRemoteRoot $tlsRemoteRoot/tls-$variant $tlsRemoteRoot $tlsMode"
    $tlsResult | Write-Output
    if ($LASTEXITCODE -ne 0 -or ($tlsResult -join "`n") -match 'FAIL' -or ($tlsResult -join "`n") -notmatch 'PASS') {
        throw "Native TLS $variant regression failed."
    }
}
foreach ($testFile in ($tlsTransferFiles + @('libc++_shared.so'))) {
    Invoke-TlsTool $tlsHdc @('-t', $Device, 'shell', 'rm', "$tlsRemoteRoot/$testFile")
}
Invoke-TlsTool $tlsHdc @('-t', $Device, 'shell', 'rmdir', $tlsRemoteRoot)
