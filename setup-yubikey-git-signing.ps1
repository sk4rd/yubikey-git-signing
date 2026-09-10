<#
    setup-yubikey-git-signing.ps1

    Sets up commit and tag signing with a YubiKey (OpenPGP applet) on Windows, and
    makes it survive reboots.  No administrator rights needed.  Safe to re-run.

    What it does
      1. finds git and the GnuPG that ships with Git for Windows (the one git will use)
      2. writes scdaemon.conf with "pcsc-shared" for that GnuPG and for every other
         GnuPG installation it finds (Gpg4win etc.).  Without this, a second GnuPG
         takes the smart card exclusively and the pending operation waits forever on
         "Please insert the card with serial number: ..." even though the key is in.
         This has to be in place BEFORE the card is touched - a GnuPG that has not
         got it cannot see a card another GnuPG is holding.
      3. makes sure the card's public key is in the keyring (fetching it from the URL
         stored on the card, or telling you how to import it), which creates the
         shadow key stubs that let gpg sign with the card
      4. sets gpg.program, commit.gpgsign, tag.gpgsign and user.signingkey in git
      5. installs a logon script (<home>\bin\start-gpg-agent.cmd) and an HKCU Run
         entry so the agent is up after a reboot, with a repair pass that clears
         wedged daemons and dead socket files if the card is not visible
      6. with -Test, makes and verifies one throwaway signature (asks for your PIN)

    Examples
      powershell -ExecutionPolicy Bypass -File setup-yubikey-git-signing.ps1 `
          -GitName "Jane Doe" -GitEmail jane@example.com -Test

      .\setup-yubikey-git-signing.ps1                # keep existing git identity
      .\setup-yubikey-git-signing.ps1 -GitRoot "D:\Tools\Git"
#>
[CmdletBinding()]
param(
    # git identity to set (only used when given, or when git has none yet)
    [string]$GitName,
    [string]$GitEmail,
    # signing key; default is the card's signature subkey fingerprint
    [string]$SigningKey,
    # Git for Windows install root, e.g. "C:\Program Files\Git"; auto-detected
    [string]$GitRoot,
    # also enable gpg-agent's ssh-agent support (YubiKey as an SSH key)
    [switch]$WithSshSupport,
    # make one throwaway signature to prove the card works (prompts for the PIN)
    [switch]$Test
)

$ErrorActionPreference = 'Continue'
$script:Failed = $false
$script:LastExit = 0
$script:WroteFiles = New-Object System.Collections.ArrayList

function Say  { param($m) Write-Host $m }
function Step { param($m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Note { param($m) Write-Host "    $m" -ForegroundColor Gray }
function Good { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Bad  { param($m) Write-Host "  X $m" -ForegroundColor Red; $script:Failed = $true }

# Run a program with arguments, return stdout+stderr as one string, keep the exit code.
function Invoke-Tool {
    param([string]$Exe, [string[]]$ToolArgs)
    $out = & $Exe @ToolArgs 2>&1
    $script:LastExit = $LASTEXITCODE
    $text = (($out | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    }) -join "`n")
    return $text
}

# "C:\Users\jane\.gnupg" -> "/c/Users/jane/.gnupg"  (Git's GnuPG wants this form)
function ConvertTo-MsysPath {
    param([string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLower() + $Matches[2] }
    return $p
}

# Pull "Reader ..........: value" style fields out of gpg --card-status output.
function Get-CardField {
    param([string]$Text, [string]$Label)
    foreach ($line in ($Text -split "`n")) {
        if ($line -match ('^\s*' + [regex]::Escape($Label) + '\s*\.*\s*:\s*(.*)$')) { return $Matches[1].Trim() }
    }
    return ''
}

# $Home would collide with PowerShell's read-only $HOME, hence -GpgHome.
function Write-ScdaemonShared {
    param([string]$GpgHome)
    if (-not (Test-Path $GpgHome)) { New-Item -ItemType Directory -Path $GpgHome -Force | Out-Null }
    $path = Join-Path $GpgHome 'scdaemon.conf'
    $already = $false
    if (Test-Path $path) {
        $existing = Get-Content $path
        if ($existing -match '^\s*pcsc-shared\s*$') { $already = $true }
    }
    if ($already) {
        Note "$path already has pcsc-shared"
        return
    }
    $lines = @(
        '# Written by setup-yubikey-git-signing.ps1',
        '# Two GnuPG installations on one machine (e.g. Git for Windows + Gpg4win) can',
        '# both use the same YubiKey.  By default each opens the PC/SC card exclusively,',
        '# so whichever one touches it first locks the other out, and that one then sits',
        '# on "Please insert the card with serial number: ..." forever.  Shared mode',
        '# lets them take turns.',
        'pcsc-shared'
    )
    if (Test-Path $path) {
        Copy-Item $path "$path.bak" -Force
        Note "kept old file as $path.bak"
    }
    Set-Content -Path $path -Value ($lines -join "`r`n") -Encoding ASCII
    if (-not ((Get-Content $path -ErrorAction SilentlyContinue) -match '^\s*pcsc-shared\s*$')) {
        Bad "could not write pcsc-shared to $path"
        return
    }
    [void]$script:WroteFiles.Add($path)
    Good "wrote $path"
}

# Add a line to a config file only if that option is not there yet (never clobbers
# settings).  -OptionName matches any existing line that sets the same option, so
# running this twice does not stack duplicates.
function Add-ConfigLine {
    param([string]$Path, [string]$Line, [string]$OptionName)
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
    $want = if ($OptionName) { $OptionName } else { $Line }
    foreach ($l in Get-Content $Path) {
        if ($l -match ('^\s*' + [regex]::Escape($want) + '(\s|$)')) {
            Note "$(Split-Path $Path -Leaf) already sets $want"
            return
        }
    }
    Add-Content -Path $Path -Value $Line -Encoding ASCII
    [void]$script:WroteFiles.Add($Path)
    Good "added to $(Split-Path $Path -Leaf): $Line"
}

# ---------------------------------------------------------------- 1. find things
Step 'Finding git and the GnuPG that git will use'

$gitExe = $null
$cmd = Get-Command git.exe -ErrorAction SilentlyContinue
if ($cmd) { $gitExe = $cmd.Source }

if ($GitRoot) {
    # explicit -GitRoot is respected, not second-guessed
    if (-not (Test-Path (Join-Path $GitRoot 'usr\bin\gpg.exe'))) {
        Bad "-GitRoot '$GitRoot' is not a Git for Windows install (no usr\bin\gpg.exe in it)"
        exit 1
    }
} elseif ($gitExe) {
    # git.exe can live in <root>\cmd, <root>\bin or <root>\mingw64\bin: walk up
    $probe = Split-Path $gitExe -Parent
    for ($i = 0; $i -lt 4 -and $probe; $i++) {
        if (Test-Path (Join-Path $probe 'usr\bin\gpg.exe')) { $GitRoot = $probe; break }
        $probe = Split-Path $probe -Parent
    }
}
if (-not $GitRoot) {
    foreach ($cand in @("$env:ProgramFiles\Git", "${env:ProgramFiles(x86)}\Git", "$env:LOCALAPPDATA\Programs\Git")) {
        if (Test-Path (Join-Path $cand 'usr\bin\gpg.exe')) { $GitRoot = $cand; break }
    }
}
if (-not $GitRoot) {
    Bad 'Git for Windows not found.'
    Say ''
    Say 'Install it first, for example:  winget install --id Git.Git'
    Say 'or pass the install root:        -GitRoot "D:\Tools\Git"'
    exit 1
}
$gpgExe = Join-Path $GitRoot 'usr\bin\gpg.exe'
if (-not $GitRoot -or -not (Test-Path $gpgExe)) {
    Bad 'Git for Windows not found (no <Git>\usr\bin\gpg.exe).'
    Say ''
    Say 'Install it first, for example:  winget install --id Git.Git'
    Say 'or pass the install root:        -GitRoot "D:\Tools\Git"'
    exit 1
}
if (-not $gitExe) { $gitExe = Join-Path $GitRoot 'cmd\git.exe' }
$script:GnuPgBin = Join-Path $GitRoot 'usr\bin'
$gitHomeWin = Join-Path $env:USERPROFILE '.gnupg'
$gitHome    = ConvertTo-MsysPath $gitHomeWin        # /c/Users/jane/.gnupg
$gitHomeSl  = $gitHome -replace '/', '\'            # \c\Users\jane\.gnupg (for cmd files)
$gpgconfExe = Join-Path $script:GnuPgBin 'gpgconf.exe'

Good "git:        $gitExe"
Good "git's GnuPG: $gpgExe"
Good "GnuPG home:  $gitHomeWin"

# other GnuPG installs on this machine (each one is a potential card thief)
$otherGpgconf = @()
foreach ($p in @(
        "$env:ProgramFiles\GnuPG\bin\gpgconf.exe",
        "$env:ProgramFiles\Gpg4win\bin\gpgconf.exe",
        "${env:ProgramFiles(x86)}\GNU\GnuPG\bin\gpgconf.exe",
        "${env:ProgramFiles(x86)}\Gpg4win\bin\gpgconf.exe")) {
    if (Test-Path $p) { $otherGpgconf += $p }
}
if ($otherGpgconf.Count -gt 0) { Note ("other GnuPG found: " + ($otherGpgconf -join ', ')) }

# ------------------------------------------------------------- 2. shared smart card
Step 'Allowing several GnuPG installations to share the smart card'
Write-ScdaemonShared -GpgHome $gitHomeWin

$otherHomes = @()
foreach ($gc in $otherGpgconf) {
    $h = (Invoke-Tool $gc @('--list-dirs', 'homedir')).Trim()
    if ($script:LastExit -ne 0 -or [string]::IsNullOrWhiteSpace($h)) {
        Warn "could not ask $gc for its home directory, skipping it"
        continue
    }
    if ($otherHomes -notcontains $h) { $otherHomes += $h }
}
foreach ($h in $otherHomes) {
    if ((ConvertTo-MsysPath $h) -eq $gitHome) { continue }
    Note "other GnuPG home: $h"
    Write-ScdaemonShared -GpgHome $h
}
if ($otherHomes.Count -eq 0) { Note 'no second GnuPG installation to configure' }

# ---------------------------------------------------------- 3. agent config
Step "Setting up $gitHomeWin\gpg-agent.conf"
$agentConf = Join-Path $gitHomeWin 'gpg-agent.conf'
if (-not (Test-Path $agentConf)) {
    Set-Content -Path $agentConf -Value '# gpg-agent config for YubiKey OpenPGP' -Encoding ASCII
    [void]$script:WroteFiles.Add($agentConf)
}
# a GUI pinentry, otherwise commits from a GUI (VS Code, GUI clients) hang
$pinentry = Join-Path $script:GnuPgBin 'pinentry-w32.exe'
if (Test-Path $pinentry) { Add-ConfigLine -Path $agentConf -Line 'pinentry-program /usr/bin/pinentry-w32' -OptionName 'pinentry-program' }
else { Warn 'pinentry-w32.exe not found in Git\usr\bin, leaving pinentry alone' }
# keep a log so a future failure can be diagnosed
Add-ConfigLine -Path $agentConf -Line ('log-file ' + (Join-Path $gitHomeWin 'gpg-agent.log').Replace('\', '/')) -OptionName 'log-file'
if ($WithSshSupport) { Add-ConfigLine -Path $agentConf -Line 'enable-ssh-support' -OptionName 'enable-ssh-support' }

# ------------------------------------------------------ 4. restart the daemons
Step 'Restarting the GnuPG daemons so the new config takes effect'
[void](Invoke-Tool $gpgconfExe @('--kill', 'all'))
foreach ($gc in $otherGpgconf) { [void](Invoke-Tool $gc @('--kill', 'all')) }
Start-Sleep -Seconds 2
Good 'daemons stopped (they restart on demand)'

# ------------------------------------------------------------- 5. the card
Step 'Looking for the YubiKey'
$card = Invoke-Tool $gpgExe @('--homedir', $gitHome, '--card-status')
$reader  = Get-CardField $card 'Reader'
$serial  = Get-CardField $card 'Serial number'
$sigKey  = (Get-CardField $card 'Signature key') -replace '\s', ''
$keyUrl  = Get-CardField $card 'URL of public key'
$cardOk  = ($script:LastExit -eq 0 -and $serial)

if (-not $cardOk) {
    Bad 'the YubiKey is not reachable'
    Say ''
    Say '  Plug the YubiKey in and run this script again.  If it IS plugged in:'
    Say '    * unplug it and plug it back in (the smart card driver sometimes'
    Say '      fails to load at boot and only re-enumeration fixes that)'
    Say '    * close other things that may hold it (Yubico Authenticator, Kleopatra)'
    Say '    * make sure no other GnuPG command is stuck, then re-run this script'
} else {
    Good "reader: $reader"
    Good "card serial: $serial"
    if ($sigKey) { Good "card signing key: $sigKey" } else { Warn 'card reports no signature key' }
}
if (-not $SigningKey) { $SigningKey = $sigKey }

# ------------------------------------------------- 6. public key + key stubs
if ($cardOk) {
    Step 'Making sure the card''s public key is in your keyring'
    $haveKey = $false
    if ($SigningKey) {
        [void](Invoke-Tool $gpgExe @('--homedir', $gitHome, '--list-keys', $SigningKey))
        $haveKey = ($script:LastExit -eq 0)
    }
    if ($haveKey) {
        Note 'already imported'
    } elseif ($keyUrl) {
        Note "fetching from the URL stored on the card: $keyUrl"
        [void](Invoke-Tool $gpgExe @('--homedir', $gitHome, '--fetch-keys', $keyUrl))
        if ($script:LastExit -ne 0) {
            Note 'that failed, trying the card''s own fetch command'
            $feed = "fetch`nquit`n"
            [void]($feed | & $gpgExe --homedir $gitHome --command-fd 0 --card-edit 2>&1)
        }
    }
    if ($SigningKey) {
        [void](Invoke-Tool $gpgExe @('--homedir', $gitHome, '--list-keys', $SigningKey))
        $haveKey = ($script:LastExit -eq 0)
    }
    if ($haveKey) {
        Good 'public key present'
        # one more card access writes the shadow key stubs used for signing
        [void](Invoke-Tool $gpgExe @('--homedir', $gitHome, '--card-status'))
        $stubs = @(Get-ChildItem (Join-Path $gitHomeWin 'private-keys-v1.d') -Filter *.key -ErrorAction SilentlyContinue)
        if ($stubs.Count -gt 0) { Good ("key stubs in place: " + $stubs.Count + " file(s) in private-keys-v1.d") }
        else { Warn 'no key stubs were created yet; the first signature should do it' }
    } else {
        Warn 'the public key is not in your keyring yet - signing cannot work without it'
        Say ''
        Say '  On a machine that already has it, run:'
        Say '      gpg --export --armor <your-key-id> > pub.asc'
        Say '  copy pub.asc over and run:'
        Say ('      "' + $gpgExe + '" --homedir ' + $gitHome + ' --import pub.asc')
        Say '  Point the card at a keyserver instead if you like, then re-run this script.'
    }
}

# ---------------------------------------------------------------- 7. git config
Step 'Configuring git'
$gpgProgram = (Join-Path $script:GnuPgBin 'gpg.exe') -replace '\\', '/'
[void](Invoke-Tool $gitExe @('config', '--global', 'gpg.program', $gpgProgram))
Good "gpg.program = $gpgProgram"
[void](Invoke-Tool $gitExe @('config', '--global', 'commit.gpgsign', 'true'))
[void](Invoke-Tool $gitExe @('config', '--global', 'tag.gpgsign', 'true'))
Good 'commit.gpgsign = true, tag.gpgsign = true'

$fmt = (Invoke-Tool $gitExe @('config', '--global', '--get', 'gpg.format')).Trim()
if ($fmt -and $fmt -ne 'openpgp') { Warn "git gpg.format is '$fmt'; this setup expects openpgp" }

if ($GitName)  { [void](Invoke-Tool $gitExe @('config', '--global', 'user.name',  $GitName));  Good "user.name = $GitName" }
if ($GitEmail) { [void](Invoke-Tool $gitExe @('config', '--global', 'user.email', $GitEmail)); Good "user.email = $GitEmail" }
foreach ($k in @('user.name', 'user.email')) {
    $v = (Invoke-Tool $gitExe @('config', '--global', '--get', $k)).Trim()
    if (-not $v) { Warn "$k is not set; git will refuse to commit until you set it" }
}
if ($SigningKey) {
    [void](Invoke-Tool $gitExe @('config', '--global', 'user.signingkey', $SigningKey))
    Good "user.signingkey = $SigningKey"
} else {
    Warn 'no signing key detected, so user.signingkey was left alone'
}

# ---------------------------------------------------- 8. logon autostart
Step 'Installing the logon autostart'

$binDir = Join-Path $env:USERPROFILE 'bin'
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
$logonCmd = Join-Path $binDir 'start-gpg-agent.cmd'

$template = @'
@echo off
rem Starts the GnuPG agent that git uses for YubiKey commit signing, and
rem repairs the two things that usually stop it working:
rem   * dead socket files left behind by a reboot
rem   * a stale or foreign scdaemon holding the smart card
rem Installed by setup-yubikey-git-signing.ps1, run at logon from
rem HKCU\...\CurrentVersion\Run (value: GpgAgentYubiSSH).
rem HOME has to be a POSIX path - Git's GnuPG binaries cannot use "C:\..." as a home.

setlocal
set "HOME=__MSYSHOME__"
set "USERPROFILE=__USERPROFILE__"
set "GNUPGBIN=__GNUPGBIN__"
set "PATH=%GNUPGBIN%;%PATH%"

call :wait_for_card
if not errorlevel 1 goto :ok

echo gpg: YubiKey not visible, restarting the GnuPG daemons...
taskkill /F /IM scdaemon.exe >nul 2>&1
taskkill /F /IM gpg-agent.exe >nul 2>&1
del /q "__USERPROFILE__\.gnupg\S.gpg-agent" "__USERPROFILE__\.gnupg\S.gpg-agent.ssh" "__USERPROFILE__\.gnupg\S.gpg-agent.extra" "__USERPROFILE__\.gnupg\S.gpg-agent.browser" "__USERPROFILE__\.gnupg\S.scdaemon" "__USERPROFILE__\.gnupg\S.keyboxd" 2>nul
"%GNUPGBIN%\gpgconf.exe" --launch gpg-agent >nul 2>&1

call :wait_for_card
if not errorlevel 1 goto :ok

echo gpg: YubiKey still not visible. If it is plugged in, unplug and replug it.
exit /b 1

:ok
exit /b 0

:wait_for_card
rem wait up to ~30s for the reader and card to show up
for /l %%i in (1,1,15) do (
    "%GNUPGBIN%\gpg.exe" --card-status >nul 2>&1
    if not errorlevel 1 exit /b 0
    ping -n 2 127.0.0.1 >nul
)
exit /b 1
'@

$content = $template.Replace('__MSYSHOME__', (ConvertTo-MsysPath $env:USERPROFILE)).
                      Replace('__USERPROFILE__', $env:USERPROFILE).
                      Replace('__GNUPGBIN__', $script:GnuPgBin)
$content = $content -replace "`r?`n", "`r`n"
Set-Content -Path $logonCmd -Value $content -Encoding ASCII
[void]$script:WroteFiles.Add($logonCmd)
Good "wrote $logonCmd"

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-ItemProperty -Path $runKey -Name 'GpgAgentYubiSSH' -Value ('cmd /c "' + $logonCmd + '"') -PropertyType String -Force | Out-Null
Good 'registered HKCU Run entry GpgAgentYubiSSH'

# ---------------------------------------------------- 9. optional test signature
if ($Test) {
    Step 'Making a test signature'
    Note 'a pinentry window will appear, asking for the YubiKey PIN (it can pop up'
    Note 'behind other windows)'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yubitest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $data = Join-Path $tmp 'data.txt'
    $sig  = Join-Path $tmp 'data.sig'
    Set-Content -Path $data -Value 'yubikey signing test' -Encoding ASCII
    # every option must come before the file, or gpg treats it as another filename
    $signArgs = @('--homedir', $gitHome, '--yes', '--armor', '--detach-sign')
    if ($SigningKey) { $signArgs += @('--local-user', $SigningKey) }
    $signArgs += @('--output', (ConvertTo-MsysPath $sig), (ConvertTo-MsysPath $data))
    $signOut = Invoke-Tool $gpgExe $signArgs
    if ($script:LastExit -eq 0) {
        $verify = Invoke-Tool $gpgExe @('--homedir', $gitHome, '--verify', (ConvertTo-MsysPath $sig), (ConvertTo-MsysPath $data))
        if ($verify -match 'Good signature') { Good 'signature made with the YubiKey and verified' }
        else { Warn "signed, but verification said: $verify" }
    } else {
        Warn "signing with the card failed (gpg exit $script:LastExit)"
        foreach ($l in (($signOut -split "`n") | Where-Object { $_ -match '\S' } | Select-Object -Last 4)) { Note $l }
        Note 'if that says the pinentry was cancelled, nothing was typed in the window'
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- 10. summary
Step 'Summary'
[void](Invoke-Tool $gpgExe @('--homedir', $gitHome, '--card-status'))
if ($script:LastExit -eq 0) {
    Good "git's GnuPG sees the card (serial $(Get-CardField $card 'Serial number'))"
} else {
    Bad "git's GnuPG cannot see the card right now"
}
foreach ($gc in $otherGpgconf) {
    $otherGpg = Join-Path (Split-Path $gc -Parent) 'gpg.exe'
    if (-not (Test-Path $otherGpg)) { continue }
    $otherOut = Invoke-Tool $otherGpg @('--card-status')
    if ($script:LastExit -eq 0) {
        Good "second GnuPG also sees the card - shared access works"
    } else {
        Warn ("second GnuPG cannot see the card: " + ((($otherOut -split "`n") | Where-Object { $_ -match 'gpg:' }) -join ' '))
    }
}
Note ('files written: ' + (($script:WroteFiles | Select-Object -Unique) -join '; '))
Say ''
if ($script:Failed) {
    Say 'Finished with problems - see the messages above.' -ForegroundColor Red
    exit 1
}
Say 'Done. Your commits and tags will be signed by the YubiKey.' -ForegroundColor Green
Say 'Test it in any repo:  git commit --allow-empty -S -m "signing test"'
Say 'After a reboot the first signature asks for your PIN (then it is cached ~10 min).'
exit 0
