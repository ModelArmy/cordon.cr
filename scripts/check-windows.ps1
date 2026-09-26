<#
.SYNOPSIS
Checks whether Cordon's Windows sandbox works on this machine, and optionally
installs the sandbox tool it relies on.

.DESCRIPTION
Cordon sandboxes commands on Windows through Microsoft's MXC tool,
wxc-exec.exe. This script:

1. With -Install, downloads the MXC version Cordon is tested against from the
   npm registry, verifies its SHA-512 hash and Microsoft signature, and
   installs it. Node.js is not needed.
2. Locates wxc-exec.exe, checks that Windows provides the process security
   environment Cordon requires, and runs a few real sandboxed commands to
   confirm each is allowed or denied as expected.

Prints "Cordon supported!" and exits 0 on success. On failure, prints the
reason and the path to a log with details, and exits 1.

wxc-exec.exe is looked up in this order; the first match wins:
  -WxcExec, the CORDON_WXC_EXEC environment variable, the per-user install
  folder, the all-users install folder, PATH, a global npm install of
  @microsoft/mxc-sdk.

.PARAMETER Install
Download and install MXC before checking.

.PARAMETER AllUsers
With -Install, install for all users under Program Files. Requires an
elevated (administrator) PowerShell. Without it, MXC is installed for the
current user only, which needs no administrator rights.

.PARAMETER InstallDir
With -Install, install to this folder instead. Cordon will not find it
automatically: set CORDON_WXC_EXEC to the wxc-exec.exe inside it.

.PARAMETER WxcExec
Path to wxc-exec.exe to check, overriding the lookup order.

.PARAMETER NetworkTarget
HTTPS address for the network checks. The network checks are skipped when
this machine cannot reach it outside the sandbox.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\check-windows.ps1
Checks an existing installation.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\check-windows.ps1 -Install
Installs MXC for the current user, then checks.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\check-windows.ps1 -Install -AllUsers
Installs MXC for all users (run elevated, e.g. by IT), then checks.
#>
param(
    [switch]$Install,
    [switch]$AllUsers,
    [string]$InstallDir,
    [string]$WxcExec,
    [string]$NetworkTarget = 'https://1.1.1.1'
)

$MxcVersion = '0.8.0'
$MxcIntegrity = 'sha512-pnf5QsASwp+qtRi5uth2GDjwuyG0rHWRpxCf3RbAjQ4wDTNfBX/9l0A+RVZspU2agpF3/11uWB1JisIS7WrNYg=='

$ErrorActionPreference = 'Stop'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$userDir = Join-Path $env:LOCALAPPDATA "cordon\mxc\$MxcVersion"
$machineDir = Join-Path $env:ProgramFiles "cordon\mxc\$MxcVersion"
$work = Join-Path $env:TEMP ('cordon-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dirs = @{}
foreach ($d in 'ro', 'rw', 'secret') {
    $dirs[$d] = (New-Item -ItemType Directory -Path (Join-Path $work $d)).FullName
}
Set-Content -Path (Join-Path $dirs.ro 'r.txt') -Value 'readable'
Set-Content -Path (Join-Path $dirs.secret 's.txt') -Value 'secret'
$log = Join-Path $work 'cordon-check.log'

function Write-Log([string]$Text) { Add-Content -Path $log -Value $Text }

function Stop-Check([string]$Reason) {
    Write-Log "`nFAILED: $Reason"
    Write-Host "Cordon is not supported on this machine: $Reason" -ForegroundColor Red
    Write-Host "Details: $log"
    exit 1
}

# Runs a native command and returns its exit code and combined output, without
# PowerShell turning stderr lines into terminating errors.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}

# Fails the check unless the file carries a valid Microsoft Authenticode signature.
function Assert-MicrosoftSigned([string]$Path) {
    $sig = Get-AuthenticodeSignature $Path
    Write-Log "Signature of ${Path}: $($sig.Status) $($sig.SignerCertificate.Subject)"
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Stop-Check "$Path is not validly signed by Microsoft (status: $($sig.Status))."
    }
}

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "OS: $($os.ProductName) $($os.DisplayVersion) build $($os.CurrentBuild).$($os.UBR)"
Write-Log "Elevated: $elevated"
if ([int]$os.CurrentBuild -lt 26100) {
    Stop-Check "Windows 11 24H2 (build 26100) or later is required; this is build $($os.CurrentBuild)."
}

# Install: download the pinned package, verify its hash against the value
# pinned above, copy the tools for this CPU architecture, verify the signature.
if ($Install) {
    $target = if ($InstallDir) { $InstallDir } elseif ($AllUsers) { $machineDir } else { $userDir }
    if ($AllUsers -and -not $elevated) {
        Stop-Check '-AllUsers needs an elevated (administrator) PowerShell.'
    }
    Write-Host "Installing MXC $MxcVersion to $target"
    $tgz = Join-Path $work "mxc-sdk-$MxcVersion.tgz"
    $dl = Invoke-Native curl.exe @('-fsSL', '-o', $tgz, "https://registry.npmjs.org/@microsoft/mxc-sdk/-/mxc-sdk-$MxcVersion.tgz")
    if ($dl.Code -ne 0) { Write-Log $dl.Output; Stop-Check "download failed (curl exit $($dl.Code))." }
    $hex = (Get-FileHash $tgz -Algorithm SHA512).Hash
    $bytes = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    $integrity = 'sha512-' + [Convert]::ToBase64String($bytes)
    Write-Log "Downloaded integrity: $integrity"
    if ($integrity -ne $MxcIntegrity) { Stop-Check 'the downloaded package does not match the expected SHA-512 hash.' }
    $pkg = New-Item -ItemType Directory -Path (Join-Path $work 'pkg')
    $x = Invoke-Native tar.exe @('-xzf', $tgz, '-C', $pkg.FullName)
    if ($x.Code -ne 0) { Write-Log $x.Output; Stop-Check "extracting the package failed (tar exit $($x.Code))." }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $pkg.FullName "package\bin\$arch\*") -Destination $target -Recurse -Force
    Copy-Item -Path (Join-Path $pkg.FullName 'package\LICENSE.md') -Destination $target -Force
    $WxcExec = Join-Path $target 'wxc-exec.exe'
    Assert-MicrosoftSigned $WxcExec
    Write-Host "Installed $WxcExec"
    if ($InstallDir) { Write-Host "Set CORDON_WXC_EXEC=$WxcExec so Cordon can find it." -ForegroundColor Yellow }
}

$candidates = @(
    $WxcExec,
    $env:CORDON_WXC_EXEC,
    (Join-Path $userDir 'wxc-exec.exe'),
    (Join-Path $machineDir 'wxc-exec.exe'),
    (Get-Command wxc-exec.exe -ErrorAction SilentlyContinue).Source,
    (Join-Path $env:APPDATA "npm\node_modules\@microsoft\mxc-sdk\bin\$arch\wxc-exec.exe")
) | Where-Object { $_ }
Write-Log "wxc-exec candidates:`n  $($candidates -join "`n  ")"
$wxc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $wxc) {
    Stop-Check 'wxc-exec.exe was not found. Re-run with -Install, set CORDON_WXC_EXEC to its path, or pass -WxcExec.'
}
Write-Log "Using: $wxc"
Assert-MicrosoftSigned $wxc

# The sandbox must use the OS process security environment (PSEC), which
# confines each process without modifying ACLs on the host.
$probe = Invoke-Native $wxc @('--probe')
Write-Log "`n=== wxc-exec --probe (exit $($probe.Code)) ===`n$($probe.Output)"
if ($probe.Code -ne 0) { Stop-Check "wxc-exec.exe --probe failed (exit $($probe.Code))." }
if ($probe.Output -notmatch '"tier"\s*:\s*"([^"]+)"') { Stop-Check 'could not read the sandbox tier from wxc-exec.exe --probe.' }
$tier = $Matches[1]
if ($tier -ne 'base-container') {
    Stop-Check "the Windows process security environment is unavailable (MXC selected '$tier'). Install the latest Windows updates and retry."
}

$aclBefore = @{}
foreach ($d in $dirs.Keys) { $aclBefore[$d] = (Get-Acl $dirs[$d]).Sddl }

$failures = New-Object System.Collections.Generic.List[string]

# Runs one command under a Cordon-like policy and records whether it was
# allowed or denied as expected. A denial only counts when cmd.exe printed its
# marker, so a sandbox that failed to launch cannot pass as enforcement.
function Test-Probe {
    param([string]$Name, [string]$Command, [string[]]$Ro = @(), [switch]$Network,
          [int]$ExpectCode = 0, [switch]$ExpectDenied, [string]$ExpectOutput)
    $cfg = [ordered]@{
        version     = '0.6.0-alpha'
        containerId = 'cordon-check-' + [guid]::NewGuid().ToString('N')
        containment = 'processcontainer'
        process     = [ordered]@{ commandLine = $Command; cwd = $dirs.rw; timeout = 30000 }
        filesystem  = [ordered]@{ readonlyPaths = @($Ro); readwritePaths = @($dirs.rw) }
        network     = [ordered]@{ defaultPolicy = $(if ($Network) { 'allow' } else { 'block' }); enforcementMode = 'capabilities' }
        fallback    = [ordered]@{ allowDaclMutation = $false }
        ui          = [ordered]@{ disable = $false }
    }
    $json = $cfg | ConvertTo-Json -Depth 5
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $r = Invoke-Native $wxc @('--config-base64', $b64)
    $pass = if ($ExpectDenied) { ($r.Output -match 'STARTED') -and $r.Code -ne 0 } else { $r.Code -eq $ExpectCode }
    if ($pass -and $ExpectOutput) { $pass = $r.Output -match [regex]::Escape($ExpectOutput) }
    Write-Log "`n[$(if ($pass) { 'PASS' } else { 'FAIL' })] $Name (exit $($r.Code))`n$json`n--- output ---`n$($r.Output)"
    if (-not $pass) { $failures.Add($Name) }
}

# The caret keeps the literal marker out of the command line, so it can only
# appear in output if cmd.exe actually ran.
function Cmd([string]$Body) { "cmd.exe /d /s /c `"echo STAR^TED& $Body`"" }

$ro = $dirs.ro; $rw = $dirs.rw; $secret = $dirs.secret
Test-Probe 'command runs' (Cmd 'echo hello') -ExpectOutput 'hello'
Test-Probe 'exit code passes through' (Cmd 'exit 7') -ExpectCode 7
Test-Probe 'granted path is readable' (Cmd "type `"$ro\r.txt`"") -Ro $ro -ExpectOutput 'readable'
Test-Probe 'read-only path is not writable' (Cmd "echo x> `"$ro\new.txt`"") -Ro $ro -ExpectDenied
Test-Probe 'read-write path is writable' (Cmd "echo x> `"$rw\new.txt`"")
Test-Probe 'ungranted path is not readable' (Cmd "type `"$secret\s.txt`"") -ExpectDenied
Test-Probe 'PowerShell starts' 'powershell.exe -NoProfile -NonInteractive -Command "exit 0"'

$networkNote = ''
$baseline = Invoke-Native curl.exe @('-sS', '-k', '-o', 'NUL', '-m', '10', $NetworkTarget)
Write-Log "`n=== host network baseline: $NetworkTarget (exit $($baseline.Code)) ===`n$($baseline.Output)"
if ($baseline.Code -eq 0) {
    $curl = "curl.exe -sS -k -o NUL -m 10 $NetworkTarget"
    Test-Probe 'network is blocked by default' (Cmd $curl) -ExpectDenied
    Test-Probe 'network is allowed when granted' (Cmd $curl) -Network
} else {
    $networkNote = " (network checks skipped: this machine cannot reach $NetworkTarget)"
    Write-Log 'Network checks skipped.'
}

foreach ($d in $aclBefore.Keys) {
    if ((Get-Acl $dirs[$d]).Sddl -ne $aclBefore[$d]) { $failures.Add("host ACLs unchanged ($d)") }
}

if ($failures.Count -gt 0) {
    Stop-Check "$($failures.Count) check(s) failed: $($failures -join '; ')."
}

Remove-Item $work -Recurse -Force
Write-Host "Cordon supported!$networkNote" -ForegroundColor Green
exit 0
