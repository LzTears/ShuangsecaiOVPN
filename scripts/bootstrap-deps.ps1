$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$dependencyLock = Get-Content -LiteralPath (Join-Path $projectRoot 'deps.lock.json') -Raw | ConvertFrom-Json
$dependencyRoot = Join-Path $projectRoot 'third_party'
New-Item -ItemType Directory -Path $dependencyRoot -Force | Out-Null

foreach ($dependencyName in @('openvpn3', 'mbedtls', 'asio')) {
    $dependency = $dependencyLock.$dependencyName
    $checkout = Join-Path $dependencyRoot $dependencyName
    if (-not (Test-Path -LiteralPath $checkout)) {
        git clone --depth 1 --branch $dependency.tag $dependency.url $checkout
        if ($LASTEXITCODE -ne 0) { throw "Could not download $dependencyName." }
    }
    $actualCommit = git -C $checkout rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $dependency.commit) {
        throw "$dependencyName does not match deps.lock.json. Existing files were not changed."
    }
    if ($dependencyName -eq 'mbedtls') {
        git -C $checkout submodule update --init --depth 1 framework
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the pinned Mbed TLS framework.' }
        $frameworkCommit = git -C (Join-Path $checkout 'framework') rev-parse HEAD
        if ($frameworkCommit -ne $dependency.frameworkCommit) { throw 'Mbed TLS framework revision mismatch.' }
    }
    Write-Output "$dependencyName verified: $actualCommit"
}

$openvpnCheckout = Join-Path $dependencyRoot 'openvpn3'
$hostnamePatch = Join-Path $projectRoot 'patches/openvpn3-mbedtls-hostname-policy.patch'
git -C $openvpnCheckout apply --reverse --check $hostnamePatch 2>$null
if ($LASTEXITCODE -ne 0) {
    git -C $openvpnCheckout apply --check $hostnamePatch
    if ($LASTEXITCODE -ne 0) { throw 'OpenVPN Mbed TLS hostname patch does not match the pinned source.' }
    git -C $openvpnCheckout apply $hostnamePatch
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply the OpenVPN Mbed TLS hostname patch.' }
}
Write-Output 'OpenVPN Mbed TLS hostname policy patch verified.'
