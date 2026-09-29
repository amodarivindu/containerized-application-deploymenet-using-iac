# Starts a Jenkins agent as YOUR Windows user (no administrator rights needed).
# Builds then run as you: Git's sh is on the PATH and Docker Desktop is accessible.
#
# Usage (keep the window open while builds run):
#   .\scripts\start-jenkins-agent.ps1 -Secret <secret from the node page>
#
# If PowerShell blocks the script, run it with:
#   powershell -ExecutionPolicy Bypass -File .\scripts\start-jenkins-agent.ps1 -Secret <secret>

param(
    [Parameter(Mandatory = $true)] [string] $Secret,
    [string] $JenkinsUrl = "http://localhost:8080/",
    [string] $AgentName  = "local",
    [string] $WorkDir    = "$HOME\jenkins-agent"
)

$ErrorActionPreference = "Stop"

# Git's Unix tools: sh (for pipeline sh steps) and nohup, etc. (used by Jenkins' sh wrapper)
$git = "$env:LOCALAPPDATA\Programs\Git"
if (-not (Test-Path "$git\bin\sh.exe")) { $git = "C:\Program Files\Git" }
if (-not (Test-Path "$git\bin\sh.exe")) { throw "Git for Windows not found. Install it or edit `$git in this script." }
$env:Path = "$env:Path;$git\bin;$git\usr\bin"

foreach ($tool in "java", "docker", "terraform", "aws", "sh") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' is not on the PATH." }
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$jar = Join-Path $WorkDir "agent.jar"
if (-not (Test-Path $jar)) {
    Write-Host "Downloading agent.jar from $JenkinsUrl"
    Invoke-WebRequest -Uri ($JenkinsUrl.TrimEnd("/") + "/jnlpJars/agent.jar") -OutFile $jar -UseBasicParsing
}

Write-Host "Starting Jenkins agent '$AgentName' (workdir $WorkDir). Press Ctrl+C to stop."
& java --enable-native-access=ALL-UNNAMED -jar $jar -url $JenkinsUrl -name $AgentName -secret $Secret -webSocket -workDir $WorkDir
