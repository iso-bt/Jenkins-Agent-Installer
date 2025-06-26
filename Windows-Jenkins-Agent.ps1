# Check for admin rights
function Ensure-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    if (-not $isAdmin) {
        Write-Host "⚠ Administrator privileges required. Restarting script as admin..." -ForegroundColor Yellow
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit
    }
}

Ensure-Admin

Write-Host "`n=== Jenkins Node Agent Setup ===`n" -ForegroundColor Cyan

# === Prompt user for paths and settings ===

$defaultAgentDir = "C:\jenkins_agent"
$agentDir = Read-Host "Enter agent directory (default: $defaultAgentDir)"
if ([string]::IsNullOrWhiteSpace($agentDir)) { $agentDir = $defaultAgentDir }

$defaultJarUrl = "https://jenkins.iso.org/jnlpJars/agent.jar"
$agentJarUrl = Read-Host "Enter agent.jar URL (default: $defaultJarUrl)"
if ([string]::IsNullOrWhiteSpace($agentJarUrl)) { $agentJarUrl = $defaultJarUrl }

$defaultJenkinsUrl = "https://jenkins.iso.org/"
$jenkinsUrl = Read-Host "Enter Jenkins controller URL (default: $defaultJenkinsUrl)"
if ([string]::IsNullOrWhiteSpace($jenkinsUrl)) { $jenkinsUrl = $defaultJenkinsUrl }

$defaultWorkDir = "C:\jenkins"
$jenkinsWorkDir = Read-Host "Enter Jenkins work directory (default: $defaultWorkDir)"
if ([string]::IsNullOrWhiteSpace($jenkinsWorkDir)) { $jenkinsWorkDir = $defaultWorkDir }

$defaultJavaPath = "C:\Program Files\Java\jdk-17\bin\java.exe"
$javaPath = Read-Host "Enter Java path (default: $defaultJavaPath)"
if ([string]::IsNullOrWhiteSpace($javaPath)) { $javaPath = $defaultJavaPath }

# Check if java path is local
if ($javaPath -like "\\*") {
    Write-Host "❌ ERROR: Java path points to a network location (UNC). Scheduled Tasks cannot access UNC paths." -ForegroundColor Red
    Write-Host "➡ Please copy Java to a local path (e.g., C:\Java\bin\java.exe) and try again."
    exit 1
}

if (!(Test-Path $javaPath)) {
    Write-Host "❌ Java not found at: $javaPath" -ForegroundColor Red
    exit 1
}

# === agent.jar download ===
$agentJar = Join-Path $agentDir "agent.jar"
if (!(Test-Path $agentDir)) {
    New-Item -ItemType Directory -Path $agentDir | Out-Null
}

$downloadAgent = $true
if (Test-Path $agentJar) {
    $response = Read-Host "agent.jar already exists. Update it? (Y/N)"
    if ($response -notin @("Y", "y")) {
        $downloadAgent = $false
    }
}

if ($downloadAgent) {
    Write-Host "Downloading agent.jar..." -ForegroundColor Yellow
    try {
        Invoke-WebRequest -Uri $agentJarUrl -OutFile $agentJar -UseBasicParsing
        Write-Host "✅ agent.jar downloaded." -ForegroundColor Green
    } catch {
        Write-Host "❌ Download failed: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Using existing agent.jar." -ForegroundColor Yellow
}

# === Jenkins info ===
$hostname = $env:COMPUTERNAME
Write-Host "`nDetected hostname: $hostname"

do {
    $jenkinsSecret = Read-Host "Enter Jenkins node secret (required)"
} while ([string]::IsNullOrWhiteSpace($jenkinsSecret))

$jenkinsName = Read-Host "Enter node name (default: $hostname)"
if ([string]::IsNullOrWhiteSpace($jenkinsName)) { $jenkinsName = $hostname }

# === Arguments ===
$agentParams = @(
    "-jar", $agentJar,
    "-url", $jenkinsUrl,
    "-secret", $jenkinsSecret,
    "-name", $jenkinsName,
    "-webSocket",
    "-workDir", $jenkinsWorkDir
)

$taskCreated = $false

# === Scheduled Task ===
$createTask = Read-Host "`nInstall as Scheduled Task with daily and startup triggers? (Y/N)"
if ($createTask -in @("Y", "y")) {

    if (Get-ScheduledTask -TaskName "JenkinsAgent" -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName "JenkinsAgent" -Confirm:$false
        Write-Host "Removed existing task." -ForegroundColor DarkYellow
    }

    $action = New-ScheduledTaskAction -Execute $javaPath -Argument ($agentParams -join ' ')

    # Trigger 1: At startup
    $triggerStartup = New-ScheduledTaskTrigger -AtStartup

    # Trigger 2: Daily at 08:00
    $triggerDaily = New-ScheduledTaskTrigger -Daily -At 08:00AM

    try {
        Register-ScheduledTask -TaskName "JenkinsAgent" `
            -Action $action `
            -Trigger @($triggerStartup, $triggerDaily) `
            -RunLevel Highest `
            -User "SYSTEM" `
            -Description "Jenkins Agent - auto start at boot and daily"
        Write-Host "`n✅ Scheduled Task with daily & startup triggers created." -ForegroundColor Green
        $taskCreated = $true
    } catch {
        Write-Host "❌ Failed to create Scheduled Task: $_" -ForegroundColor Red
    }
}

# === Run Now ===
$runNow = Read-Host "`nDo you want to start the Jenkins Agent now? (Y/N)"
if ($runNow -in @("Y", "y")) {
    if ($taskCreated) {
        try {
            Start-ScheduledTask -TaskName "JenkinsAgent"
            Write-Host "▶ Scheduled Task started." -ForegroundColor Green
        } catch {
            Write-Host "❌ Failed to start scheduled task: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "▶ Running Jenkins Agent manually..." -ForegroundColor Yellow
        & $javaPath @agentParams
    }
} else {
    Write-Host "`n⏸ Jenkins Agent not started. You can run it manually anytime." -ForegroundColor Cyan
}
