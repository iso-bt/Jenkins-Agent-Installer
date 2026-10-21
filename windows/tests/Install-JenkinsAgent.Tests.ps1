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
$prevCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
Assert-True 'tr-TR buyuk I'       { Test-AgentName 'BUILDIST01' }
[Threading.Thread]::CurrentThread.CurrentCulture = $prevCulture
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
Assert-True 'wrapper fonksiyonlar'    { $wrapper.Contains('function Get-AgentProcess {') -and $wrapper.Contains('function Get-AgentNamePattern {') -and $wrapper.Contains('function Get-TrustArgument {') }
Assert-True 'wrapper varsayilan Windows' { $wrapper.Contains("`$TrustMode  = 'Windows'") }
foreach ($mode in 'Pinned', 'Insecure') {
    $modeWrapper = New-WrapperScript -AgentName 'build-01' -JenkinsUrl 'https://jenkins.example.com/' -JavaExe 'C:\java\bin\java.exe' -InstallDir 'C:\jenkins agent' -WorkDir 'C:\jenkins' -TrustMode $mode
    $modeErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($modeWrapper, [ref]$null, [ref]$modeErrors) | Out-Null
    Assert-True "wrapper $mode parse hatasiz" { $modeErrors.Count -eq 0 }
    Assert-True "wrapper $mode modu"          { $modeWrapper.Contains("`$TrustMode  = '$mode'") -and $modeWrapper.Contains("`$TrustStore = 'C:\jenkins agent\truststore.p12'") }
}

# Sertifika
$pinnedArgs = Get-TrustArgument 'Pinned' 'C:\a b\truststore.p12' 'changeit'
Assert-True 'pinned java argumanlari' { ($pinnedArgs.Java -join '|') -eq '-Djavax.net.ssl.trustStore=C:\a b\truststore.p12|-Djavax.net.ssl.trustStoreType=PKCS12|-Djavax.net.ssl.trustStorePassword=changeit' }
Assert-True 'pinned agent argumani yok' { @($pinnedArgs.Agent).Count -eq 0 }
$windowsArgs = Get-TrustArgument 'Windows' 'x' 'y'
Assert-True 'windows java argumani'   { ($windowsArgs.Java -join '|') -eq '-Djavax.net.ssl.trustStoreType=Windows-ROOT' -and @($windowsArgs.Agent).Count -eq 0 }
$insecureArgs = Get-TrustArgument 'Insecure' 'x' 'y'
Assert-True 'insecure agent argumani' { ($insecureArgs.Agent -join '|') -eq '-noCertificateCheck' -and -not (($insecureArgs.Java -join ' ') -match 'trustStore=') }
Assert-True 'storepass sabit'         { $TrustStorePassword -eq 'changeit' -and $TrustStoreFile -eq 'truststore.p12' }
$sha = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
Assert-True 'thumbprint ayni'         { (ConvertTo-Thumbprint $sha) -eq $sha }
Assert-True 'thumbprint kucuk ve :'   { (ConvertTo-Thumbprint (($sha.ToLowerInvariant() -split '(..)' | Where-Object { $_ }) -join ':')) -eq $sha }
Assert-True 'thumbprint bosluklu'     { (ConvertTo-Thumbprint (' ' + $sha.Substring(0, 32) + ' ' + $sha.Substring(32) + ' ')) -eq $sha }
Assert-True 'thumbprint kisa red'     { $null -eq (ConvertTo-Thumbprint 'ABCD') }
Assert-True 'thumbprint SHA-1 red'    { $null -eq (ConvertTo-Thumbprint ('A' * 40)) }
Assert-True 'thumbprint hex disi red' { $null -eq (ConvertTo-Thumbprint ('G' * 64)) }
Assert-True 'thumbprint bos red'      { $null -eq (ConvertTo-Thumbprint '') }
Assert-True 'kendinden imzali'        { Test-IsSelfIssued 'CN=Corp Root, DC=corp' 'CN=Corp Root, DC=corp' }
Assert-True 'site sertifikasi'        { -not (Test-IsSelfIssued 'CN=jenkins.corp' 'CN=Corp Root, DC=corp') }
Initialize-TlsHelper
Assert-True 'sha256 hesap'            { [JenkinsAgentTls]::GetSha256([Text.Encoding]::ASCII.GetBytes('abc')) -eq $sha }
Assert-True 'pin: hatasiz zincir'     { [JenkinsAgentTls]::IsPinnedChainValid($null, 'None', $sha) }
Assert-True 'pin: ad uyusmazligi red' { -not [JenkinsAgentTls]::IsPinnedChainValid($null, 'RemoteCertificateNameMismatch', $sha) }
Assert-True 'pin: zincir yok red'     { -not [JenkinsAgentTls]::IsPinnedChainValid($null, 'RemoteCertificateChainErrors', $sha) }
Assert-True 'global callback yok'     { $null -eq [Net.ServicePointManager]::ServerCertificateValidationCallback }
Assert-True 'http TLS kontrolu yok'   { $null -eq (Get-JenkinsTls 'http://jenkins.example.com/') }
Assert-True 'http Windows modu'       { (Resolve-TrustMode -Probe $null -TrustStorePath 'C:\yok\truststore.p12').Mode -eq 'Windows' }
Assert-True 'olmayan truststore bos'  { @(Get-TrustStoreThumbprint 'C:\yok\truststore.p12').Count -eq 0 }

# Guven karari (sahte probe)
$rsa = [Security.Cryptography.RSA]::Create(2048)
$certRequest = New-Object Security.Cryptography.X509Certificates.CertificateRequest('CN=Test Root', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
$testCert = $certRequest.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(1)).RawData
$testSha = [JenkinsAgentTls]::GetSha256($testCert)
function New-FakeProbe([string] $PolicyErrors = 'RemoteCertificateChainErrors', [string] $ChainProblems = 'NoError', $Certificate = $testCert) {
    $probe = New-Object JenkinsAgentTlsProbe
    $probe.PolicyErrors = $PolicyErrors
    $probe.ChainProblems = $ChainProblems
    $probe.TopCertificate = $Certificate
    return $probe
}
function Invoke-Trust($Probe, [string[]] $Answers = @()) {
    # Read-Host sirayla verilen cevaplari doner; sorulan soru sayisi $script:Asked'da.
    $script:Answers = $Answers
    $script:Asked = 0
    try { return (Resolve-TrustMode -Probe $Probe -TrustStorePath 'C:\yok\truststore.p12' 6>$null).Mode }
    catch { return 'THROW' }
}
function Read-Host { $answer = $script:Answers[$script:Asked]; $script:Asked++; return $answer }
$untrusted = New-FakeProbe
$expired = New-FakeProbe -ChainProblems 'NotTimeValid'

$NonInteractive = $true; $Force = $true
Assert-True 'NI+Force parametresiz red'   { (Invoke-Trust $untrusted) -eq 'THROW' }
Assert-True 'NI+Force suresi gecmis red'  { (Invoke-Trust $expired) -eq 'THROW' }
$TrustedCertThumbprint = $testSha.ToLowerInvariant()
Assert-True 'NI thumbprint eslesir'       { (Invoke-Trust $untrusted) -eq 'Pinned' }
Assert-True 'NI thumbprint suresi gecmis' { (Invoke-Trust $expired) -eq 'THROW' }
$TrustedCertThumbprint = '0' * 64
Assert-True 'NI thumbprint uyusmaz'       { (Invoke-Trust $untrusted) -eq 'THROW' }
$TrustedCertThumbprint = $null
Assert-True 'ad uyusmazligi red'          { (Invoke-Trust (New-FakeProbe -PolicyErrors 'RemoteCertificateNameMismatch')) -eq 'THROW' }
Assert-True 'sertifika yok red'           { (Invoke-Trust (New-FakeProbe -PolicyErrors 'RemoteCertificateNotAvailable' -Certificate $null)) -eq 'THROW' }
$SkipCertificateCheck = $true
Assert-True 'sertifika yok + Skip'        { (Invoke-Trust (New-FakeProbe -PolicyErrors 'RemoteCertificateNotAvailable' -Certificate $null)) -eq 'Insecure' }
$SkipCertificateCheck = $false
Assert-True 'Windows guveniyor'           { (Resolve-TrustMode -Probe (New-Object JenkinsAgentTlsProbe -Property @{ Trusted = $true }) -TrustStorePath 'x' 6>$null).Mode -eq 'Windows' }

$NonInteractive = $false
Assert-True 'Force pin onayini vermez'    { (Invoke-Trust $untrusted @('1', '')) -eq 'THROW' }
Assert-True 'Force bypass onayini vermez' { (Invoke-Trust $untrusted @('2', '')) -eq 'THROW' }
$Force = $false
Assert-True 'pin onayla'                  { (Invoke-Trust $untrusted @('1', 'e')) -eq 'Pinned' }
Assert-True 'bypass onayla'               { (Invoke-Trust $untrusted @('2', 'e')) -eq 'Insecure' }
Assert-True 'iptal'                       { (Invoke-Trust $untrusted @('3')) -eq 'THROW' }
Assert-True 'gecersiz secim tekrar sorar' { ((Invoke-Trust $untrusted @('4', 'x', '1', 'e')) -eq 'Pinned') -and $script:Asked -eq 4 }
Assert-True 'suresi gecmis pin sunulmaz'  { ((Invoke-Trust $expired @('1', '3')) -eq 'THROW') -and $script:Asked -eq 2 }
Assert-True 'suresi gecmis varsayilan iptal' { (Invoke-Trust $expired @('')) -eq 'THROW' }
Assert-True 'suresi gecmis bypass'        { (Invoke-Trust $expired @('2', 'e')) -eq 'Insecure' }
Remove-Item function:Read-Host

# Sistem proxy'si
$prevProxy = [Net.WebRequest]::DefaultWebProxy
[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy('http://proxy.local:8080', $false, [string[]] @('jenkins\.direct\.org'))
Assert-True 'proxy tespit edilir'     { (Get-SystemProxy 'https://jenkins.example.com/') -eq 'http://proxy.local:8080/' }
Assert-True 'proxy bypass listesi'    { $null -eq (Get-SystemProxy 'https://jenkins.direct.org/') }
[Net.WebRequest]::DefaultWebProxy = $prevProxy

# Mod degisince eski truststore silinir
$storeDir = Join-Path $env:TEMP ('jat-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $storeDir | Out-Null
try {
    foreach ($mode in 'Windows', 'Insecure') {
        $store = Join-Path $storeDir 'truststore.p12'
        Set-Content -LiteralPath $store -Value 'eski'
        Set-TrustStore -Trust @{ Mode = $mode } -JavaExe 'C:\yok\java.exe' -Path $store -Identity $null 6>$null
        Assert-True "$mode modunda truststore silinir" { -not (Test-Path -LiteralPath $store) }
    }
} finally {
    Remove-Item -LiteralPath $storeDir -Recurse -Force
}

# Ana script: parse, BOM yok (irm | iex bozulur), sadece ASCII
$scriptPath = Join-Path $PSScriptRoot '..\Install-JenkinsAgent.ps1'
$scriptErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath).ProviderPath, [ref]$null, [ref]$scriptErrors) | Out-Null
$bytes = [IO.File]::ReadAllBytes((Resolve-Path $scriptPath).ProviderPath)
Assert-True 'script parse hatasiz'    { $scriptErrors.Count -eq 0 }
Assert-True 'script BOM yok'          { -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) }
Assert-True 'script sadece ASCII'     { @($bytes | Where-Object { $_ -gt 127 }).Count -eq 0 }

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host "$script:Failed test basarisiz." -ForegroundColor Red
    exit 1
}
Write-Host 'Tum testler gecti.' -ForegroundColor Green
