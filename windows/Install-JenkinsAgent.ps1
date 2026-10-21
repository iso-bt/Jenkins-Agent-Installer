<#
.SYNOPSIS
    Jenkins inbound (webSocket) agent kurulumu - Windows.

.DESCRIPTION
    Adim adim sorarak (veya parametrelerle sormadan) bir Jenkins inbound agent kurar:
      - Java (Temurin indir / klasor yolu / klasor sec), surum >= 17 kontrolu
      - agent.jar indirme
      - secret dosyasi (sadece SYSTEM, Administrators ve gorev hesabi okuyabilir)
      - start-agent.ps1 wrapper'i (ayni node icin ikinci java baslatmaz)
      - "JenkinsAgent-<AgentName>" zamanlanmis gorevi (acilista + dakikada bir)

    Windows PowerShell 5.1 ile calisir. Yonetici yetkisi gerekir.

.EXAMPLE
    .\Install-JenkinsAgent.ps1

.EXAMPLE
    .\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -JavaMode Download -NonInteractive -Secret <secret>

.EXAMPLE
    .\Install-JenkinsAgent.ps1 -Uninstall -AgentName build-01
#>
[CmdletBinding()]
param(
    [string] $JenkinsUrl,
    [string] $AgentName,
    [string] $Secret,
    [string] $InstallDir,
    [string] $WorkDir,
    [string] $JavaHome,
    # Download | Path | Browse. ValidateSet yok: irm | iex altinda bos degerle hata veriyor.
    [string] $JavaMode,
    [int] $JavaVersion = 25,
    [string] $RunAs,
    [pscredential] $RunAsCredential,
    [switch] $Uninstall,
    # Soru sorma; verilmeyen degerler icin varsayilanlari kullan.
    [switch] $NonInteractive,
    # Onay sorularina (agent.jar ustune yaz, klasoru sil vb.) evet de.
    [switch] $Force
)

$ScriptUrl = 'https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1'

$DefaultInstallDir = 'C:\jenkins-agent'
$DefaultWorkDir = 'C:\jenkins'
$MinJavaMajor = 17
$TotalSteps = 8

$BoundArgs = @{}
if ($PSBoundParameters) {
    foreach ($key in $PSBoundParameters.Keys) { $BoundArgs[$key] = $PSBoundParameters[$key] }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Yardimci fonksiyonlar (testler bunlari dot-source ederek kullanir)
# ---------------------------------------------------------------------------

function Write-Step([int] $Number, [string] $Text) {
    Write-Host ''
    Write-Host ('[{0}/{1}] {2}' -f $Number, $TotalSteps, $Text) -ForegroundColor Cyan
}

function Write-Info([string] $Text) { Write-Host "  $Text" }
function Write-Ok([string] $Text) { Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn([string] $Text) { Write-Host "  $Text" -ForegroundColor Yellow }

function Read-Value {
    param([string] $Prompt, [string] $Default, [switch] $Required)
    if ($NonInteractive) {
        if ($Required -and -not $Default) { throw "$Prompt verilmedi (-NonInteractive modunda parametre olarak verin)." }
        return $Default
    }
    $suffix = ''
    if ($Default) { $suffix = " [$Default]" }
    while ($true) {
        $value = Read-Host "  $Prompt$suffix"
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        if ($Default -or -not $Required) { return $Default }
    }
}

function Confirm-Choice([string] $Question, [bool] $Default) {
    if ($Force) { return $true }
    if ($NonInteractive) { return $Default }
    $hint = 'e/H'
    if ($Default) { $hint = 'E/h' }
    $answer = Read-Host "  $Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return ($answer.Trim() -match '^(e|evet|y|yes)$')
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NormalizedJenkinsUrl([string] $Url) {
    $value = "$Url".Trim()
    if ($value -notmatch '^https?://[^/\s]+') {
        throw "Gecersiz Jenkins URL: '$Url' (http:// veya https:// ile baslamali)."
    }
    return $value.TrimEnd('/') + '/'
}

function Get-AgentJarUrl([string] $Url) {
    return (Get-NormalizedJenkinsUrl $Url) + 'jnlpJars/agent.jar'
}

function Test-AgentName([string] $Name) {
    # Gorev adi, dosya adi ve regex icinde kullanildigi icin sade karakterlerle sinirli.
    # -cmatch: tr-TR kulturunde -match buyuk 'I' harfini [A-Za-z] ile eslestirmiyor.
    return ($Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$')
}

function Test-IsUncPath([string] $Path) {
    return ("$Path".Trim().Trim('"') -like '\\*')
}

function Assert-LocalPath([string] $Path) {
    if (Test-IsUncPath $Path) { throw "Ag (UNC) yolu desteklenmiyor: $Path. Yerel bir klasor verin." }
}

function Test-IsSystemAccount([string] $Account) {
    return ((-not $Account) -or ($Account -match '^(NT AUTHORITY\\)?SYSTEM$') -or ($Account -eq 'S-1-5-18'))
}

function Get-JavaMajorVersion([string] $VersionText) {
    # openjdk version "25" 2025-09-16 / "17.0.12" / java version "1.8.0_421"
    if ($VersionText -notmatch 'version "(\d+)(?:\.(\d+))?') { return 0 }
    $major = [int] $Matches[1]
    if ($major -eq 1 -and $Matches[2]) { $major = [int] $Matches[2] }
    return $major
}

function Resolve-JavaExe([string] $Path) {
    # JAVA_HOME, bin klasoru veya java.exe yolunu kabul eder; bulunamazsa $null doner.
    $value = "$Path".Trim().Trim('"')
    if (-not $value) { return $null }
    if (Test-IsUncPath $value) { throw "Ag (UNC) yolu desteklenmiyor: $value. Java'yi yerel diske kopyalayin." }
    if ((Split-Path -Leaf $value) -ieq 'java.exe') {
        $candidates = @($value)
    } else {
        $candidates = @((Join-Path $value 'bin\java.exe'), (Join-Path $value 'java.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
    }
    return $null
}

function Get-JavaVersionText([string] $JavaExe) {
    # java -version stderr'e yazar; 5.1'de Stop tercihinde bu bir hata kaydina donusur.
    $ErrorActionPreference = 'Continue'
    return ((& $JavaExe -version 2>&1 | ForEach-Object { "$_" }) -join "`n")
}

function Test-JavaExe([string] $JavaExe) {
    $major = Get-JavaMajorVersion (Get-JavaVersionText $JavaExe)
    if ($major -lt $MinJavaMajor) {
        throw "Java surumu $MinJavaMajor veya ustu olmali (bulunan: $major): $JavaExe"
    }
    return $major
}

function Get-TemurinUrl([int] $Version, [string] $ImageType) {
    return 'https://api.adoptium.net/v3/binary/latest/{0}/ga/windows/x64/{1}/hotspot/normal/eclipse' -f $Version, $ImageType
}

function Save-Download([string] $Url, [string] $OutFile) {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Install-Temurin([int] $Version, [string] $JavaRoot, $Identity) {
    if (-not (Test-Path -LiteralPath $JavaRoot)) {
        New-Item -ItemType Directory -Path $JavaRoot | Out-Null
        # java.exe gorev hesabiyla (cogunlukla SYSTEM) calisir, standart kullanicilar degistirememeli.
        Set-RestrictedAcl -Path $JavaRoot -Identity $Identity -Rights 'ReadAndExecute'
    }
    $zip = Join-Path $env:TEMP ('temurin-{0}.zip' -f [guid]::NewGuid())
    $extract = Join-Path $JavaRoot ('_extract-{0}' -f [guid]::NewGuid())
    try {
        $downloaded = $false
        foreach ($imageType in @('jre', 'jdk')) {
            $url = Get-TemurinUrl -Version $Version -ImageType $imageType
            try {
                Write-Info "Indiriliyor: $url"
                Save-Download $url $zip
                $downloaded = $true
                break
            } catch {
                Write-Warn "Temurin $Version $imageType indirilemedi: $($_.Exception.Message)"
            }
        }
        if (-not $downloaded) { throw "Temurin $Version indirilemedi." }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)
        $top = @(Get-ChildItem -LiteralPath $extract -Directory)
        if ($top.Count -ne 1) { throw 'Java arsivinin yapisi beklenenden farkli.' }
        $target = Join-Path $JavaRoot $top[0].Name
        if (Test-Path -LiteralPath $target) {
            Write-Info "Bu surum zaten var, mevcut klasor kullaniliyor: $target"
        } else {
            Move-Item -LiteralPath $top[0].FullName -Destination $target
        }
        return $target
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

function Select-FolderDialog {
    # Server Core veya STA olmayan oturumlarda $null doner, cagiran yolu elle sorar.
    try {
        if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { return $null }
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Java klasorunu secin (JAVA_HOME veya bin)'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    } catch {
        Write-Warn "Klasor secme penceresi acilamadi: $($_.Exception.Message)"
    }
    return $null
}

function Get-JavaCandidatePath([string] $Mode, [string] $JavaRoot, $Identity) {
    if ($Mode -eq 'Download') { return (Install-Temurin -Version $JavaVersion -JavaRoot $JavaRoot -Identity $Identity) }
    if ($Mode -eq 'Browse') {
        $selected = Select-FolderDialog
        if ($selected) { return $selected }
        Write-Warn 'Klasor secilmedi, yolu elle girin.'
    }
    return (Read-Value 'Java klasoru (JAVA_HOME, bin veya java.exe yolu)' '' -Required)
}

function Read-JavaMode {
    if ($JavaHome) { return 'Path' }
    if ($JavaMode) {
        if ($JavaMode -notin @('Download', 'Path', 'Browse')) { throw "Gecersiz -JavaMode: $JavaMode (Download, Path veya Browse)." }
        return $JavaMode
    }
    if ($NonInteractive) { return 'Download' }
    Write-Info "1) Temurin $JavaVersion indir (onerilen)"
    Write-Info '2) Java klasor yolunu yaz'
    Write-Info '3) Java klasorunu pencereden sec'
    $choice = Read-Value 'Secim' '1'
    switch ($choice) {
        '2' { return 'Path' }
        '3' { return 'Browse' }
        default { return 'Download' }
    }
}

function Get-JavaExe([string] $JavaRoot, $Identity) {
    $mode = Read-JavaMode
    $path = $JavaHome
    while ($true) {
        try {
            if (-not $path) { $path = Get-JavaCandidatePath -Mode $mode -JavaRoot $JavaRoot -Identity $Identity }
            $javaExe = Resolve-JavaExe $path
            if (-not $javaExe) { throw "java.exe bulunamadi: $path" }
            $major = Test-JavaExe $javaExe
            Write-Ok "Java $major bulundu: $javaExe"
            return $javaExe
        } catch {
            if ($NonInteractive -or $mode -eq 'Download') { throw }
            Write-Warn $_.Exception.Message
            $path = $null
        }
    }
}

function Get-AccountIdentity([string] $Account) {
    if (Test-IsSystemAccount $Account) { return New-Object Security.Principal.SecurityIdentifier('S-1-5-18') }
    $name = $Account -replace '^\.\\', "$env:COMPUTERNAME\"
    $identity = New-Object Security.Principal.NTAccount($name)
    $identity.Translate([Security.Principal.SecurityIdentifier]) | Out-Null
    return $identity
}

function Set-RestrictedAcl {
    # Mirasi kapatir; sadece SYSTEM, Administrators (tam yetki) ve gorev hesabi erisebilir.
    param([string] $Path, $Identity, [string] $Rights)
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $inherit = [Security.AccessControl.InheritanceFlags] 'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $inherit = [Security.AccessControl.InheritanceFlags] 'None'
    }
    $acl.SetAccessRuleProtection($true, $false)
    $entries = @(
        @((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')), 'FullControl'),
        @((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')), 'FullControl'),
        @($Identity, $Rights)
    )
    foreach ($entry in $entries) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($entry[0], $entry[1], $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $item.SetAccessControl($acl)
}

function ConvertTo-PlainText([securestring] $Value) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-LockedFile([string] $Path, $Identity, [string] $Rights) {
    # Once bos dosya + ACL, sonra icerik: icerik hic genis yetkili bir dosyada durmaz.
    # Var olan dosyanin ustune yazmak ACL'i korur.
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType File -Path $Path | Out-Null }
    Set-RestrictedAcl -Path $Path -Identity $Identity -Rights $Rights
}

function Write-SecretFile([string] $Path, [string] $Value, $Identity) {
    New-LockedFile -Path $Path -Identity $Identity -Rights 'Read'
    [IO.File]::WriteAllText($Path, $Value.Trim(), (New-Object Text.UTF8Encoding($false)))
}

function Get-AgentNamePattern([string] $Name) {
    # "-name build-01" veya "-name \"build-01\"" eslesir, "-name build-010" eslesmez.
    return ('-name\s+(["'']?){0}\1(\s|$)' -f [regex]::Escape($Name))
}

function Get-AgentProcess([string] $Name) {
    $pattern = Get-AgentNamePattern $Name
    return @(
        Get-CimInstance -ClassName Win32_Process -Filter "Name='java.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'agent\.jar' -and $_.CommandLine -match $pattern }
    )
}

function Stop-AgentProcess([string] $Name) {
    foreach ($process in @(Get-AgentProcess $Name)) {
        Write-Info "Agent java sureci durduruluyor (PID $($process.ProcessId))"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-PsLiteral([string] $Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-TaskName([string] $Name) { return "JenkinsAgent-$Name" }

function Get-TaskArgument([string] $WrapperPath) {
    return ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $WrapperPath)
}

function Get-RelaunchArgument {
    param($Bound, [string] $ScriptPath)
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $ScriptPath))
    foreach ($key in $Bound.Keys) {
        $value = $Bound[$key]
        # Secret yeni surecin komut satirina yazilmaz, yeni pencerede tekrar sorulur.
        # Bu yuzden -NonInteractive de tasinmaz.
        if ($key -eq 'Secret') { continue }
        if ($key -eq 'NonInteractive' -and $Bound.Contains('Secret')) { continue }
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $parts += "-$key" }
            continue
        }
        # Credential komut satirindan tasinamaz, yeni pencerede tekrar sorulur.
        if ($value -is [pscredential]) { continue }
        $parts += "-$key"
        $parts += ('"{0}"' -f ([string] $value).Replace('"', '\"'))
    }
    return ($parts -join ' ')
}

$WrapperTemplate = @'
# Jenkins inbound agent baslatici. Install-JenkinsAgent.ps1 tarafindan uretildi, elle degistirmeyin.
#
# Zamanlanmis gorev bunu acilista ve dakikada bir calistirir. Bu node icin agent java.exe
# zaten calisiyorsa hicbir sey yapmadan cikar; calismiyorsa java'yi ON PLANDA calistirir,
# boylece gorev agent yasadigi surece "calisiyor" kalir. Start-Process'e cevirmeyin:
# arka planda baslayan java gorevin hemen bitmesine, bir sonraki tekrarda ayni isimle
# ikinci bir agent baslamasina yol acar; Jenkins bu durumda baglantiyi koparir ve node
# offline kalir. Gorevin MultipleInstances=IgnoreNew ayarina tek basina guvenilmez.

$ErrorActionPreference = 'Stop'

$AgentName  = __AGENT_NAME__
$JenkinsUrl = __JENKINS_URL__
$JavaExe    = __JAVA_EXE__
$AgentJar   = __AGENT_JAR__
$SecretFile = __SECRET_FILE__
$WorkDir    = __WORK_DIR__
$LogPath    = __LOG_PATH__

$MaxLogBytes  = 1MB
$KeepLogLines = 200

function Write-Log([string] $Message) {
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt $MaxLogBytes)) {
            $keep = @(Get-Content -LiteralPath $LogPath -Tail $KeepLogLines)
            Set-Content -LiteralPath $LogPath -Value $keep
        }
        Add-Content -LiteralPath $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch {
        # Log yazilamamasi agent'in baslamasini engellememeli.
    }
}

__AGENT_FUNCTIONS__

# @() sart: tek elemanli sonuc skalere donusur ve .Count bos gelir; o zaman calisan
# agent gorulmez ve ikinci bir agent baslatilir.
$running = @(Get-AgentProcess $AgentName)

if ($running.Count -gt 1) {
    Write-Log ("WARN '{0}' icin birden fazla agent calisiyor (PID {1}); node muhtemelen offline. Hepsini durdurun, gorev tekrar baslatir." -f $AgentName, (($running | ForEach-Object { $_.ProcessId }) -join ','))
    exit 0
}
if ($running.Count -eq 1) { exit 0 }

if (-not (Test-Path -LiteralPath $JavaExe)) {
    Write-Log "ERROR java bulunamadi: $JavaExe"
    exit 1
}

Write-Log ("START '{0}' icin agent calismiyor, baslatiliyor: {1}" -f $AgentName, $JavaExe)

$javaArgs = @(
    '-jar', $AgentJar,
    '-url', $JenkinsUrl,
    '-secret', ('@' + $SecretFile),
    '-name', $AgentName,
    '-webSocket',
    '-workDir', $WorkDir
)

$ErrorActionPreference = 'Continue'
& $JavaExe @javaArgs
$code = $LASTEXITCODE

Write-Log ("EXIT '{0}' java cikis kodu {1}" -f $AgentName, $code)
exit $code
'@

function New-WrapperScript {
    param([string] $AgentName, [string] $JenkinsUrl, [string] $JavaExe, [string] $InstallDir, [string] $WorkDir)
    $functions = @('Get-AgentNamePattern', 'Get-AgentProcess') | ForEach-Object {
        "function $_ {`r`n" + (Get-Item "function:$_").ScriptBlock.ToString().Trim() + "`r`n}"
    }
    $values = @{
        '__AGENT_NAME__'  = $AgentName
        '__JENKINS_URL__' = $JenkinsUrl
        '__JAVA_EXE__'    = $JavaExe
        '__AGENT_JAR__'   = (Join-Path $InstallDir 'agent.jar')
        '__SECRET_FILE__' = (Join-Path $InstallDir 'secret.txt')
        '__WORK_DIR__'    = $WorkDir
        '__LOG_PATH__'    = (Join-Path $InstallDir 'agent.log')
    }
    $text = $WrapperTemplate.Replace('__AGENT_FUNCTIONS__', ($functions -join "`r`n`r`n"))
    foreach ($key in $values.Keys) { $text = $text.Replace($key, (ConvertTo-PsLiteral $values[$key])) }
    return $text
}

function Remove-AgentTask([string] $TaskName) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }
    Write-Info "Mevcut gorev kaldiriliyor: $TaskName"
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

function Register-AgentTask {
    param([string] $TaskName, [string] $WrapperPath, [string] $InstallDir, [string] $Account, [pscredential] $Credential)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-TaskArgument $WrapperPath) -WorkingDirectory $InstallDir
    # RepetitionDuration verilmeyince tekrar suresiz olur (5.1 dahil).
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1))
    )
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $common = @{ TaskName = $TaskName; Action = $action; Trigger = $triggers; Settings = $settings; Description = 'Jenkins inbound agent' }
    if (Test-IsSystemAccount $Account) {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask @common -Principal $principal | Out-Null
    } else {
        $password = $Credential.GetNetworkCredential().Password
        Register-ScheduledTask @common -User $Credential.UserName -Password $password -RunLevel Highest | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Kurulum adimlari
# ---------------------------------------------------------------------------

function Read-AgentName {
    $name = $AgentName
    if (-not $name) { $name = Read-Value 'Agent (node) adi' $env:COMPUTERNAME -Required }
    if (-not (Test-AgentName $name)) { throw "Gecersiz agent adi: '$name' (harf, rakam, nokta, tire, alt cizgi)." }
    return $name
}

function Read-RunAsCredential {
    if ($RunAsCredential) { return $RunAsCredential }
    $account = $RunAs
    if (-not $account) { $account = Read-Value 'Gorevin calisacagi hesap (SYSTEM veya DOMAIN\kullanici)' 'SYSTEM' }
    if (Test-IsSystemAccount $account) { return $null }
    if ($NonInteractive) { throw "-RunAs $account icin -RunAsCredential verilmeli." }
    return (Get-Credential -UserName $account -Message 'Zamanlanmis gorev hesabinin parolasi')
}

function Read-SecretValue([string] $SecretPath) {
    if ($Secret) { return $Secret }
    if ((Test-Path -LiteralPath $SecretPath) -and (Confirm-Choice 'Mevcut secret dosyasi kullanilsin mi?' $true)) { return $null }
    if ($NonInteractive) { throw '-Secret verilmedi ve mevcut secret dosyasi yok.' }
    Write-Info 'Secret, Jenkins > Nodes > <agent> sayfasindaki komutta yer alir.'
    while ($true) {
        $plain = ConvertTo-PlainText (Read-Host '  Secret' -AsSecureString)
        if (-not [string]::IsNullOrWhiteSpace($plain)) { return $plain }
    }
}

function Initialize-Directory([string] $Path, $Identity) {
    # Klasorun yetkileri sadece bu script olusturduysa kisitlanir; var olan bir klasorun
    # yetkilerine dokunulmaz, onun yerine icine yazilan dosyalar tek tek kisitlanir.
    if (Test-Path -LiteralPath $Path) { return }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-RestrictedAcl -Path $Path -Identity $Identity -Rights 'Modify'
}

function Save-AgentJar([string] $Url, [string] $Path, $Identity) {
    $update = (-not (Test-Path -LiteralPath $Path)) -or (Confirm-Choice 'agent.jar zaten var, guncellensin mi?' $true)
    New-LockedFile -Path $Path -Identity $Identity -Rights 'ReadAndExecute'
    if (-not $update) {
        Write-Info 'Mevcut agent.jar kullaniliyor.'
        return
    }
    Write-Info "Indiriliyor: $Url"
    try {
        Save-Download $Url $Path
    } catch [IO.IOException] {
        # Farkli adla veya eski yontemle (-jnlpUrl) baslatilmis bir agent jar'i tutuyor olabilir.
        $holders = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='java.exe'" |
            Where-Object { $_.CommandLine -match 'agent\.jar' } | ForEach-Object { $_.ProcessId })
        throw ("agent.jar kullanimda, guncellenemedi. agent.jar calistiran java surecleri: PID {0}. Bunlari durdurup (Stop-Process -Id <PID>) tekrar deneyin." -f ($holders -join ', '))
    }
    Write-Ok 'agent.jar indirildi.'
}

function Show-TaskStatus([string] $TaskName, [string] $Name) {
    Start-Sleep -Seconds 5
    $info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
    $state = (Get-ScheduledTask -TaskName $TaskName).State
    Write-Info ("Gorev: {0}  Durum: {1}  Son sonuc: 0x{2:X}" -f $TaskName, $state, $info.LastTaskResult)
    $count = @(Get-AgentProcess $Name).Count
    if ($count -eq 1) { Write-Ok 'Agent java sureci calisiyor.' } else { Write-Warn "Calisan agent java sureci sayisi: $count" }
}

function Invoke-Install {
    Write-Step 1 'Jenkins adresi'
    $url = $JenkinsUrl
    if (-not $url) { $url = Read-Value 'Jenkins URL (ornek: https://jenkins.example.com/)' '' -Required }
    $url = Get-NormalizedJenkinsUrl $url

    Write-Step 2 'Agent adi'
    $name = Read-AgentName

    Write-Step 3 'Klasorler'
    $installPath = $InstallDir
    if (-not $installPath) { $installPath = Read-Value 'Kurulum klasoru' $DefaultInstallDir -Required }
    $workPath = $WorkDir
    if (-not $workPath) { $workPath = Read-Value 'Calisma klasoru (workDir)' $DefaultWorkDir -Required }
    Assert-LocalPath $installPath
    Assert-LocalPath $workPath

    Write-Step 4 'Gorev hesabi'
    $credential = Read-RunAsCredential
    $account = 'SYSTEM'
    if ($credential) { $account = $credential.UserName }
    $identity = Get-AccountIdentity $account
    Initialize-Directory -Path $installPath -Identity $identity
    Initialize-Directory -Path $workPath -Identity $identity
    Write-Ok "Hesap: $account"

    Write-Step 5 'Java'
    $javaExe = Get-JavaExe -JavaRoot (Join-Path $installPath 'java') -Identity $identity

    # Calisan agent agent.jar'i kilitler; eski gorev ve java jar guncellenmeden once durdurulur.
    # Eski ayarlarla calisan java kalirsa wrapper yenisini de baslatmaz.
    $taskName = Get-TaskName $name
    Remove-AgentTask $taskName
    Stop-AgentProcess $name

    Write-Step 6 'agent.jar'
    Save-AgentJar -Url (Get-AgentJarUrl $url) -Path (Join-Path $installPath 'agent.jar') -Identity $identity

    Write-Step 7 'Secret'
    $secretPath = Join-Path $installPath 'secret.txt'
    $secretValue = Read-SecretValue $secretPath
    if ($secretValue) {
        Write-SecretFile -Path $secretPath -Value $secretValue -Identity $identity
    } else {
        # Hesap degismis olabilir, mevcut dosyanin yetkileri de guncellenir.
        Set-RestrictedAcl -Path $secretPath -Identity $identity -Rights 'Read'
    }
    Write-Ok "Secret dosyasi: $secretPath"

    Write-Step 8 'Zamanlanmis gorev'
    $wrapperPath = Join-Path $installPath 'start-agent.ps1'
    $wrapper = New-WrapperScript -AgentName $name -JenkinsUrl $url -JavaExe $javaExe -InstallDir $installPath -WorkDir $workPath
    New-LockedFile -Path $wrapperPath -Identity $identity -Rights 'ReadAndExecute'
    [IO.File]::WriteAllText($wrapperPath, $wrapper, (New-Object Text.UTF8Encoding($true)))
    Register-AgentTask -TaskName $taskName -WrapperPath $wrapperPath -InstallDir $installPath -Account $account -Credential $credential
    Start-ScheduledTask -TaskName $taskName
    Show-TaskStatus -TaskName $taskName -Name $name

    Write-Host ''
    Write-Ok 'Kurulum tamamlandi.'
    Write-Info "Wrapper logu : $(Join-Path $installPath 'agent.log')"
    Write-Info "Remoting logu: $(Join-Path $workPath 'remoting\logs')"
}

function Invoke-Uninstall {
    $name = Read-AgentName
    $installPath = $InstallDir
    if (-not $installPath) { $installPath = Read-Value 'Kurulum klasoru' $DefaultInstallDir -Required }
    Remove-AgentTask (Get-TaskName $name)
    Stop-AgentProcess $name
    if ((Test-Path -LiteralPath $installPath) -and (Confirm-Choice "$installPath silinsin mi?" $false)) {
        Remove-Item -LiteralPath $installPath -Recurse -Force
        Write-Info "$installPath silindi."
    }
    Write-Ok "Agent '$name' kaldirildi. Calisma klasoru (workDir) silinmedi."
}

function Restart-Elevated {
    $path = $PSCommandPath
    if (-not $path) {
        # irm | iex ile calisiyor: dosya yok, kendini indirip yonetici olarak ac.
        # Sabit isimli dosya yerine her seferinde yeni, rastgele isimli bir klasor kullanilir.
        $folder = Join-Path $env:TEMP ('jenkins-agent-' + [IO.Path]::GetRandomFileName())
        $path = Join-Path $folder 'Install-JenkinsAgent.ps1'
        try {
            New-Item -ItemType Directory -Path $folder | Out-Null
            Save-Download $ScriptUrl $path
        } catch {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
            throw "Yonetici yetkisi gerekiyor. PowerShell'i 'Yonetici olarak calistir' ile acip komutu tekrar calistirin."
        }
    }
    Write-Warn 'Yonetici yetkisi gerekiyor, script yonetici olarak yeni pencerede aciliyor...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (Get-RelaunchArgument -Bound $BoundArgs -ScriptPath $path)
}

function Main {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if (-not (Test-IsAdmin)) {
        Restart-Elevated
        return
    }
    if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
}

# Testler dot-source ettiginde (". .\Install-JenkinsAgent.ps1") calismaz; -File, & ve irm | iex ile calisir.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Main
    } catch {
        Write-Host ''
        Write-Host ("HATA: {0}" -f $_.Exception.Message) -ForegroundColor Red
        # iex altinda exit kullanicinin penceresini kapatir.
        if ($PSCommandPath) { exit 1 }
    }
}
