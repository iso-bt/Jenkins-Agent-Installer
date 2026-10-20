# Install-JenkinsAgent.ps1 icindeki saf yardimci fonksiyonlarin testleri.
# Pester gerektirmez:  powershell.exe -NoProfile -File windows\tests\Install-JenkinsAgent.Tests.ps1
# Hata varsa cikis kodu 1 olur.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-JenkinsAgent.ps1')

$script:Failed = 0

function Assert-True([string] $Name, [scriptblock] $Test) {
    try {
        if (& $Test) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name" -ForegroundColor Red; $script:Failed++ }
    } catch {
        Write-Host "FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-Throws([string] $Name, [scriptblock] $Test) {
    $threw = $false
    try { & $Test | Out-Null } catch { $threw = $true }
    Assert-True $Name { $threw }
}

# Java surumu
Assert-True 'java 25'           { (Get-JavaMajorVersion 'openjdk version "25" 2025-09-16') -eq 25 }
Assert-True 'java 17.0.12'      { (Get-JavaMajorVersion 'openjdk version "17.0.12" 2024-07-16 LTS') -eq 17 }
Assert-True 'java 21 cok satir' { (Get-JavaMajorVersion "Picked up JAVA_TOOL_OPTIONS: -Xmx1g`nopenjdk version `"21.0.4`"") -eq 21 }
Assert-True 'java 1.8'          { (Get-JavaMajorVersion 'java version "1.8.0_421"') -eq 8 }
Assert-True 'java taninmayan'   { (Get-JavaMajorVersion 'command not found') -eq 0 }

# Java yolu
$root = Join-Path $env:TEMP ('jat-' + [guid]::NewGuid())
$bin = Join-Path $root 'jdk-25\bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$exe = Join-Path $bin 'java.exe'
Set-Content -LiteralPath $exe -Value ''
try {
    Assert-True 'JAVA_HOME klasoru'     { (Resolve-JavaExe (Join-Path $root 'jdk-25')) -eq $exe }
    Assert-True 'bin klasoru'           { (Resolve-JavaExe $bin) -eq $exe }
    Assert-True 'java.exe yolu'         { (Resolve-JavaExe $exe) -eq $exe }
    Assert-True 'tirnakli yol'          { (Resolve-JavaExe ('"' + $bin + '\"')) -eq $exe }
    Assert-True 'olmayan klasor'        { $null -eq (Resolve-JavaExe (Join-Path $root 'yok')) }
    Assert-True 'bos deger'             { $null -eq (Resolve-JavaExe '') }
    Assert-Throws 'UNC reddedilir'      { Resolve-JavaExe '\\server\share\jdk' }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}

# URL
Assert-True 'url sonuna / eklenir'   { (Get-NormalizedJenkinsUrl 'https://jenkins.example.com') -eq 'https://jenkins.example.com/' }
Assert-True 'fazla / temizlenir'     { (Get-NormalizedJenkinsUrl ' https://jenkins.example.com/// ') -eq 'https://jenkins.example.com/' }
Assert-True 'alt yol korunur'        { (Get-NormalizedJenkinsUrl 'http://ci.example.com:8080/jenkins') -eq 'http://ci.example.com:8080/jenkins/' }
Assert-True 'agent.jar url'          { (Get-AgentJarUrl 'https://jenkins.example.com') -eq 'https://jenkins.example.com/jnlpJars/agent.jar' }
Assert-Throws 'semasiz url reddedilir' { Get-NormalizedJenkinsUrl 'jenkins.example.com' }
Assert-Throws 'bos url reddedilir'     { Get-NormalizedJenkinsUrl '' }

# Agent adi ve surec eslesmesi
Assert-True 'gecerli ad'          { Test-AgentName 'build-01.win_x64' }
Assert-True 'bosluklu ad red'     { -not (Test-AgentName 'build 01') }
Assert-True 'yol karakteri red'   { -not (Test-AgentName 'a\b') }
$pattern = Get-AgentNamePattern 'build-01'
Assert-True 'ad eslesir'          { 'java -jar C:\a\agent.jar -url x -name build-01 -webSocket' -match $pattern }
Assert-True 'satir sonunda eslesir' { 'java -jar agent.jar -name build-01' -match $pattern }
Assert-True 'tirnakli ad eslesir' { 'java.exe -jar "C:\a b\agent.jar" -name "build-01" -webSocket' -match $pattern }
Assert-True 'onek eslesmez'       { -not ('java -jar agent.jar -name build-010 -webSocket' -match $pattern) }
Assert-True 'nokta joker degil'   { -not ('java -jar agent.jar -name aXb' -match (Get-AgentNamePattern 'a.b')) }

# Hesap
Assert-True 'SYSTEM'              { Test-IsSystemAccount 'SYSTEM' }
Assert-True 'NT AUTHORITY\SYSTEM' { Test-IsSystemAccount 'NT AUTHORITY\SYSTEM' }
Assert-True 'bos hesap SYSTEM'    { Test-IsSystemAccount '' }
Assert-True 'kullanici'           { -not (Test-IsSystemAccount 'CORP\svc-build') }
Assert-True 'UNC tespiti'         { (Test-IsUncPath '\\srv\x') -and -not (Test-IsUncPath 'C:\x') }

# Gorev ve yeniden baslatma argumanlari
Assert-True 'gorev argumani'      { (Get-TaskArgument 'C:\jenkins agent\start-agent.ps1') -eq '-NoProfile -ExecutionPolicy Bypass -File "C:\jenkins agent\start-agent.ps1"' }
Assert-True 'gorev adi'           { (Get-TaskName 'build-01') -eq 'JenkinsAgent-build-01' }
$password = New-Object Security.SecureString
$password.AppendChar('p')
$cred = New-Object pscredential('u', $password)
$relaunch = Get-RelaunchArgument -Bound ([ordered]@{ JenkinsUrl = 'https://jenkins.example.com/'; InstallDir = 'C:\a b'; NonInteractive = [switch]$true; Force = [switch]$false; RunAsCredential = $cred }) -ScriptPath 'C:\t\i.ps1'
Assert-True 'relaunch argumanlari' { $relaunch -eq '-NoProfile -ExecutionPolicy Bypass -NoExit -File "C:\t\i.ps1" -JenkinsUrl "https://jenkins.example.com/" -InstallDir "C:\a b" -NonInteractive' }
$relaunchSecret = Get-RelaunchArgument -Bound ([ordered]@{ AgentName = 'build-01'; Secret = 'abc123'; NonInteractive = [switch]$true }) -ScriptPath 'C:\t\i.ps1'
Assert-True 'relaunch secret tasimaz' { $relaunchSecret -eq '-NoProfile -ExecutionPolicy Bypass -NoExit -File "C:\t\i.ps1" -AgentName "build-01"' }
Assert-True 'relaunch secret yok'     { -not $relaunchSecret.Contains('abc123') }

# Yerel yol kontrolu
Assert-Throws 'UNC kurulum klasoru red' { Assert-LocalPath '\\server\share\jenkins-agent' }
Assert-True 'yerel klasor kabul'        { Assert-LocalPath 'C:\jenkins-agent'; $true }

# Uretilen wrapper
$wrapper = New-WrapperScript -AgentName 'build-01' -JenkinsUrl 'https://jenkins.example.com/' -JavaExe "C:\o'java\bin\java.exe" -InstallDir 'C:\jenkins-agent' -WorkDir 'C:\jenkins'
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$null, [ref]$parseErrors) | Out-Null
Assert-True 'wrapper parse hatasiz'   { $parseErrors.Count -eq 0 }
Assert-True 'wrapper yer tutucu yok'  { $wrapper -notmatch '__[A-Z_]+__' }
Assert-True 'wrapper tirnak kacisi'   { $wrapper.Contains("`$JavaExe    = 'C:\o''java\bin\java.exe'") }
Assert-True 'wrapper secret dosyadan' { $wrapper.Contains("'-secret', ('@' + `$SecretFile)") -and $wrapper.Contains("C:\jenkins-agent\secret.txt") }
Assert-True 'wrapper fonksiyonlar'    { $wrapper.Contains('function Get-AgentProcess {') -and $wrapper.Contains('function Get-AgentNamePattern {') }

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host "$script:Failed test basarisiz." -ForegroundColor Red
    exit 1
}
Write-Host 'Tum testler gecti.' -ForegroundColor Green
