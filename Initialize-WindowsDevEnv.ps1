#requires -Version 5.1

$ErrorActionPreference = 'Continue'

$script:Summary = [ordered]@{
    Installed = @()
    Skipped = @()
    Failed = @()
    Versions = [ordered]@{}
    Paths = [ordered]@{}
    GitUserNameConfigured = $false
    GitUserEmailConfigured = $false
    ScoopProxy = '未配置'
}

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('==== {0} ====' -f $Message) -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host ('[信息] {0}' -f $Message) -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host ('[警告] {0}' -f $Message) -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host ('[错误] {0}' -f $Message) -ForegroundColor Red
}

function Read-TrimmedInput {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) { return '' }
    return $value.Trim()
}

function Add-SummaryItem {
    param(
        [ValidateSet('Installed', 'Skipped', 'Failed')]
        [string]$Category,
        [string]$Name,
        [string]$Detail
    )

    if ([string]::IsNullOrWhiteSpace($Detail)) {
        $item = $Name
    } else {
        $item = ('{0} - {1}' -f $Name, $Detail)
    }

    if ($script:Summary[$Category] -notcontains $item) {
        $script:Summary[$Category] += $item
    }
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-ExternalCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$FailureMessage,
        [switch]$Quiet
    )

    $result = [ordered]@{ Success = $false; ExitCode = -1; Output = '' }
    try {
        if (-not $Quiet) {
            Write-Info ('执行命令：{0} {1}' -f $FilePath, ($Arguments -join ' '))
        }
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        $result.ExitCode = $exitCode
        $result.Output = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        $result.Success = ($exitCode -eq 0)
        if ((-not $result.Success) -and (-not [string]::IsNullOrWhiteSpace($FailureMessage))) {
            Write-ErrorMessage ('{0}，退出码：{1}' -f $FailureMessage, $exitCode)
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) { Write-Warn $result.Output }
        }
    } catch {
        $result.Output = $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($FailureMessage)) {
            Write-ErrorMessage ('{0}：{1}' -f $FailureMessage, $_.Exception.Message)
        }
    }
    return [pscustomobject]$result
}

function Get-CommandText {
    param([string]$FilePath, [string[]]$Arguments = @())
    try {
        $output = & $FilePath @Arguments 2>&1
        return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
    } catch {
        return $_.Exception.Message
    }
}

function Set-UserEnvironmentVariable {
    param([string]$Name, [string]$Value)
    try {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        Set-Item -Path ('Env:' + $Name) -Value $Value
        Write-Info ('已设置用户环境变量 {0}={1}' -f $Name, $Value)
        return $true
    } catch {
        Write-ErrorMessage ('设置用户环境变量 {0} 失败：{1}' -f $Name, $_.Exception.Message)
        return $false
    }
}

function Add-PathEntry {
    param([string]$PathEntry)
    if ([string]::IsNullOrWhiteSpace($PathEntry)) { return }
    try {
        if (-not (Test-Path -LiteralPath $PathEntry)) {
            Write-Warn ('PATH 目录不存在，暂不添加：{0}' -f $PathEntry)
            return
        }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $userEntries = @()
        if (-not [string]::IsNullOrWhiteSpace($userPath)) {
            $userEntries = $userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
        $exists = $false
        foreach ($entry in $userEntries) {
            if ([string]::Equals($entry.TrimEnd('\'), $PathEntry.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { $exists = $true }
        }
        if (-not $exists) {
            [Environment]::SetEnvironmentVariable('Path', (($userEntries + $PathEntry) -join ';'), 'User')
            Write-Info ('已添加到用户 PATH：{0}' -f $PathEntry)
        }
        $currentEntries = $env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $currentExists = $false
        foreach ($entry in $currentEntries) {
            if ([string]::Equals($entry.TrimEnd('\'), $PathEntry.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { $currentExists = $true }
        }
        if (-not $currentExists) { $env:Path = (($currentEntries + $PathEntry) -join ';') }
    } catch {
        Write-ErrorMessage ('更新 PATH 失败：{0}' -f $_.Exception.Message)
    }
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-TcpConnection {
    param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds = 5000)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $success = $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)
        if ($success) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}

function Test-InitialEnvironment {
    Write-Step '启动前检查'
    Write-Info ('当前 PowerShell 版本：{0}' -f $PSVersionTable.PSVersion.ToString())
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Warn '当前 PowerShell 版本低于 5.1，脚本可能无法正常运行。'
    }
    try {
        $processPolicy = Get-ExecutionPolicy -Scope Process
        $currentUserPolicy = Get-ExecutionPolicy -Scope CurrentUser
        $localMachinePolicy = Get-ExecutionPolicy -Scope LocalMachine
        Write-Info ('执行策略：Process={0}; CurrentUser={1}; LocalMachine={2}' -f $processPolicy, $currentUserPolicy, $localMachinePolicy)
        if ($processPolicy -eq 'Restricted' -and $currentUserPolicy -eq 'Restricted') {
            Write-Warn '当前执行策略可能阻止脚本或 Scoop 安装脚本运行。安装 Scoop 时会尝试设置 CurrentUser 为 RemoteSigned。'
        }
    } catch {
        Write-Warn ('读取执行策略失败：{0}' -f $_.Exception.Message)
    }
    if (Test-TcpConnection -HostName 'github.com' -Port 443) {
        Write-Info '网络检查通过：可以连接 github.com:443。'
    } else {
        Write-Warn '网络检查失败：无法连接 github.com:443，后续下载可能失败。'
    }
    if (Test-CommandExists 'scoop') { Write-Info '检测到 Scoop 已存在。' } else { Write-Info '未检测到 Scoop，将在后续步骤安装。' }
    if (Test-CommandExists 'winget') { Write-Info '检测到 winget 可用。' } else { Write-Warn '未检测到 winget；如果 Scoop 官方安装失败，将无法使用 winget 作为备用安装方式。' }
    if (Test-IsAdministrator) { Write-Warn '当前以管理员权限运行。脚本不强制要求管理员权限，Scoop 更建议以普通用户安装。' } else { Write-Info '当前不是管理员权限，符合普通用户安装方式。' }
}

function Read-DevRoot {
    Write-Step '选择开发根目录'
    $inputPath = Read-TrimmedInput '请输入开发环境根目录，直接回车使用 D:\Dev'
    if ([string]::IsNullOrWhiteSpace($inputPath)) { $inputPath = 'D:\Dev' }
    $expandedPath = [Environment]::ExpandEnvironmentVariables($inputPath)
    if ($expandedPath.StartsWith('~')) { $expandedPath = $expandedPath.Replace('~', $HOME) }
    try {
        $devRoot = [System.IO.Path]::GetFullPath($expandedPath)
        if (-not (Test-Path -LiteralPath $devRoot)) {
            New-Item -ItemType Directory -Path $devRoot -Force | Out-Null
            Write-Info ('已创建开发根目录：{0}' -f $devRoot)
        } else {
            Write-Info ('开发根目录已存在：{0}' -f $devRoot)
        }
        $caches = Join-Path $devRoot 'caches'
        $configs = Join-Path $devRoot 'configs'
        $directories = @(
            (Join-Path $devRoot 'apps'), $caches, $configs, (Join-Path $devRoot 'workspace'),
            (Join-Path $caches 'npm'), (Join-Path $caches 'pnpm-store'), (Join-Path $caches 'uv'),
            (Join-Path $caches 'pip'), (Join-Path $caches 'maven-repository'), (Join-Path $configs 'maven'),
            (Join-Path $caches 'go-build'), (Join-Path $caches 'go-mod'),
            (Join-Path (Join-Path $devRoot 'apps') 'pnpm'), (Join-Path (Join-Path $devRoot 'apps') 'go'),
            (Join-Path (Join-Path (Join-Path $devRoot 'apps') 'go') 'bin')
        )
        foreach ($directory in $directories) {
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        }
        $script:Summary.Paths['DevRoot'] = $devRoot
        $script:Summary.Paths['Workspace'] = Join-Path $devRoot 'workspace'
        $script:Summary.Paths['NpmCache'] = Join-Path $caches 'npm'
        $script:Summary.Paths['PnpmHome'] = Join-Path (Join-Path $devRoot 'apps') 'pnpm'
        $script:Summary.Paths['PnpmStore'] = Join-Path $caches 'pnpm-store'
        $script:Summary.Paths['UvCache'] = Join-Path $caches 'uv'
        $script:Summary.Paths['PipCache'] = Join-Path $caches 'pip'
        $script:Summary.Paths['MavenRepository'] = Join-Path $caches 'maven-repository'
        $script:Summary.Paths['MavenSettings'] = Join-Path (Join-Path $configs 'maven') 'settings.xml'
        $script:Summary.Paths['GoPath'] = Join-Path (Join-Path $devRoot 'apps') 'go'
        $script:Summary.Paths['GoBin'] = Join-Path (Join-Path (Join-Path $devRoot 'apps') 'go') 'bin'
        $script:Summary.Paths['GoBuildCache'] = Join-Path $caches 'go-build'
        $script:Summary.Paths['GoModCache'] = Join-Path $caches 'go-mod'
        return $devRoot
    } catch {
        Write-ErrorMessage ('开发根目录不可用：{0}' -f $_.Exception.Message)
        throw
    }
}

function Read-ScoopProxy {
    Write-Step '配置 Scoop 代理'
    $proxy = Read-TrimmedInput '请输入 Scoop proxy 地址，直接回车表示不配置，例如 http://127.0.0.1:7890'
    if ([string]::IsNullOrWhiteSpace($proxy)) {
        Write-Info '未配置 Scoop proxy。'
        $script:Summary.ScoopProxy = '未配置'
        return ''
    }
    Write-Info ('将配置 Scoop proxy：{0}' -f $proxy)
    $script:Summary.ScoopProxy = $proxy
    return $proxy
}

function Get-DevToolSuites {
    return @(
        [pscustomobject]@{
            Key = 'git'
            DisplayName = 'git'
            MenuText = 'git（必选）'
            Aliases = @('1', 'git')
        },
        [pscustomobject]@{
            Key = 'node-suite'
            DisplayName = 'node开发套件（volta + node + npm + pnpm）'
            MenuText = 'node开发套件（volta + node + npm + pnpm）（可选）'
            Aliases = @('2', 'node', 'nodejs', 'volta', 'npm', 'pnpm')
        },
        [pscustomobject]@{
            Key = 'java-suite'
            DisplayName = 'Java开发套件（jdk + maven）'
            MenuText = 'Java开发套件（jdk + maven）（可选）'
            Aliases = @('3', 'java', 'jdk', 'maven', 'mvn')
        },
        [pscustomobject]@{
            Key = 'python-suite'
            DisplayName = 'Python开发套件（python + uv）'
            MenuText = 'Python开发套件（python + uv）（可选）'
            Aliases = @('4', 'python', 'py', 'uv')
        },
        [pscustomobject]@{
            Key = 'go-suite'
            DisplayName = 'Go开发套件（go）'
            MenuText = 'Go开发套件（go）（可选）'
            Aliases = @('5', 'go', 'golang')
        }
    )
}

function Get-SelectionDisplayNames {
    param([string[]]$Selection)

    $displayNames = @()
    foreach ($suite in Get-DevToolSuites) {
        if ($Selection -contains $suite.Key) { $displayNames += $suite.DisplayName }
    }
    return $displayNames
}

function Read-InstallSelection {
    Write-Step '选择开发工具'
    Write-Host '支持安装的项目：'
    $suites = Get-DevToolSuites
    for ($index = 0; $index -lt $suites.Count; $index++) {
        Write-Host ('  {0}. {1}' -f ($index + 1), $suites[$index].MenuText)
    }
    $selectionText = Read-TrimmedInput '请输入编号或名称，逗号分隔；直接回车安装全部'

    $allSuiteKeys = @()
    $aliasMap = @{}
    foreach ($suite in $suites) {
        $allSuiteKeys += $suite.Key
        foreach ($alias in $suite.Aliases) { $aliasMap[$alias.ToLowerInvariant()] = $suite.Key }
    }

    if ([string]::IsNullOrWhiteSpace($selectionText)) { return $allSuiteKeys }

    $selected = @('git')
    foreach ($rawItem in ($selectionText -split ',')) {
        $item = $rawItem.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        if ($aliasMap.ContainsKey($item)) {
            if ($selected -notcontains $aliasMap[$item]) { $selected += $aliasMap[$item] }
        } else {
            Write-Warn ('无法识别的选择，已忽略：{0}' -f $rawItem)
        }
    }
    $ordered = @()
    foreach ($suiteKey in $allSuiteKeys) { if ($selected -contains $suiteKey) { $ordered += $suiteKey } }
    return $ordered
}

function Confirm-InstallSelection {
    param([string[]]$Selection)
    Write-Step '确认安装选择'
    Write-Host ('将安装或配置：{0}' -f ((Get-SelectionDisplayNames -Selection $Selection) -join ', ')) -ForegroundColor Green
    $answer = Read-TrimmedInput '是否继续？直接回车或输入 Y 继续，输入 N 取消'
    if ([string]::IsNullOrWhiteSpace($answer)) { return $true }
    return ($answer.ToLowerInvariant() -eq 'y' -or $answer.ToLowerInvariant() -eq 'yes')
}

function Install-Scoop {
    param([string]$DevRoot)
    Write-Step '安装 Scoop'
    $scoopRoot = Join-Path (Join-Path $DevRoot 'apps') 'scoop'
    $scoopGlobalRoot = Join-Path (Join-Path $DevRoot 'apps') 'scoop-global'
    $scoopShims = Join-Path $scoopRoot 'shims'
    if (Test-CommandExists 'scoop') {
        Write-Info 'Scoop 已安装，跳过安装。'
        Add-SummaryItem -Category 'Skipped' -Name 'Scoop' -Detail '已安装'
        $existingScoopPath = $env:SCOOP
        if ([string]::IsNullOrWhiteSpace($existingScoopPath)) { $existingScoopPath = $scoopRoot }
        $script:Summary.Paths['Scoop'] = $existingScoopPath
        return $true
    }
    try {
        if (-not (Test-Path -LiteralPath $scoopRoot)) { New-Item -ItemType Directory -Path $scoopRoot -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $scoopGlobalRoot)) { New-Item -ItemType Directory -Path $scoopGlobalRoot -Force | Out-Null }
        Set-UserEnvironmentVariable -Name 'SCOOP' -Value $scoopRoot | Out-Null
        Set-UserEnvironmentVariable -Name 'SCOOP_GLOBAL' -Value $scoopGlobalRoot | Out-Null
        try {
            $currentUserPolicy = Get-ExecutionPolicy -Scope CurrentUser
            if ($currentUserPolicy -eq 'Restricted' -or $currentUserPolicy -eq 'AllSigned') {
                Write-Info '正在设置 CurrentUser 执行策略为 RemoteSigned，以便安装 Scoop。'
                Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
            }
        } catch { Write-Warn ('设置执行策略失败，仍会尝试安装 Scoop：{0}' -f $_.Exception.Message) }
        Write-Info '正在使用官方安装脚本安装 Scoop。'
        $officialSucceeded = $false
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $installer = (New-Object Net.WebClient).DownloadString('https://get.scoop.sh')
            Invoke-Expression $installer
            Add-PathEntry -PathEntry $scoopShims
            $officialSucceeded = Test-CommandExists 'scoop'
        } catch { Write-Warn ('Scoop 官方安装脚本失败：{0}' -f $_.Exception.Message) }
        if (-not $officialSucceeded) {
            if (Test-CommandExists 'winget') {
                Write-Warn '正在尝试使用 winget 安装 Scoop。'
                $wingetResult = Invoke-ExternalCommand -FilePath 'winget' -Arguments @('install', '--id', 'ScoopInstaller.Scoop', '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements') -FailureMessage 'winget 安装 Scoop 失败'
                Add-PathEntry -PathEntry $scoopShims
                if (-not $wingetResult.Success -or -not (Test-CommandExists 'scoop')) {
                    Add-SummaryItem -Category 'Failed' -Name 'Scoop' -Detail '官方脚本和 winget 均安装失败'
                    return $false
                }
            } else {
                Add-SummaryItem -Category 'Failed' -Name 'Scoop' -Detail '官方脚本失败且 winget 不可用'
                return $false
            }
        }
        $versionResult = Invoke-ExternalCommand -FilePath 'scoop' -Arguments @('--version') -FailureMessage 'Scoop 安装后验证失败' -Quiet
        if ($versionResult.Success) {
            Add-SummaryItem -Category 'Installed' -Name 'Scoop' -Detail '安装成功'
            $script:Summary.Paths['Scoop'] = $scoopRoot
            return $true
        }
        Add-SummaryItem -Category 'Failed' -Name 'Scoop' -Detail '安装后 scoop --version 不可用'
        return $false
    } catch {
        Write-ErrorMessage ('安装 Scoop 失败：{0}' -f $_.Exception.Message)
        Add-SummaryItem -Category 'Failed' -Name 'Scoop' -Detail $_.Exception.Message
        return $false
    }
}

function Set-ScoopProxy {
    param([string]$Proxy)
    if ([string]::IsNullOrWhiteSpace($Proxy)) { Write-Info '未提供 Scoop proxy，跳过配置。'; return }
    Write-Step '设置 Scoop proxy'
    $result = Invoke-ExternalCommand -FilePath 'scoop' -Arguments @('config', 'proxy', $Proxy) -FailureMessage '设置 Scoop proxy 失败'
    if ($result.Success) { Write-Info ('Scoop proxy 已设置为：{0}' -f $Proxy) }
}

function Update-ScoopBestEffort {
    Write-Step '更新 Scoop 索引'
    $result = Invoke-ExternalCommand -FilePath 'scoop' -Arguments @('update') -FailureMessage 'scoop update 失败，将继续后续步骤'
    if ($result.Success) { Write-Info 'scoop update 完成。' }
}

function Test-ScoopPackageInstalled {
    param([string]$PackageName)
    if (-not (Test-CommandExists 'scoop')) { return $false }
    $result = Invoke-ExternalCommand -FilePath 'scoop' -Arguments @('prefix', $PackageName) -Quiet
    return $result.Success
}

function Install-ScoopPackage {
    param([string]$PackageName, [string]$DisplayName, [string]$CommandName)
    if (Test-ScoopPackageInstalled -PackageName $PackageName) {
        Write-Info ('{0} 已通过 Scoop 安装，跳过。' -f $DisplayName)
        Add-SummaryItem -Category 'Skipped' -Name $DisplayName -Detail 'Scoop 包已存在'
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($CommandName) -and (Test-CommandExists $CommandName)) {
        Write-Warn ('检测到命令 {0} 已存在，跳过 Scoop 安装 {1}。' -f $CommandName, $DisplayName)
        Add-SummaryItem -Category 'Skipped' -Name $DisplayName -Detail ('命令 {0} 已存在' -f $CommandName)
        return $true
    }
    Write-Info ('正在安装 {0}。' -f $DisplayName)
    $result = Invoke-ExternalCommand -FilePath 'scoop' -Arguments @('install', $PackageName) -FailureMessage ('安装 {0} 失败' -f $DisplayName)
    if ($result.Success) {
        Add-SummaryItem -Category 'Installed' -Name $DisplayName -Detail $PackageName
        return $true
    }
    Add-SummaryItem -Category 'Failed' -Name $DisplayName -Detail ('安装包 {0} 失败' -f $PackageName)
    return $false
}

function Add-ScoopBucket {
    param([string]$BucketName)

    Write-Info ('检查 Scoop bucket：{0}' -f $BucketName)

    $scoopRoot = $env:SCOOP
    if ([string]::IsNullOrWhiteSpace($scoopRoot) -and $script:Summary.Paths.Contains('Scoop')) {
        $scoopRoot = $script:Summary.Paths['Scoop']
    }
    if (-not [string]::IsNullOrWhiteSpace($scoopRoot)) {
        $bucketPath = Join-Path (Join-Path $scoopRoot 'buckets') $BucketName
        if (Test-Path -LiteralPath $bucketPath) {
            Write-Info ('Bucket 已存在，跳过添加：{0}' -f $BucketName)
            Add-SummaryItem -Category 'Skipped' -Name ('Scoop bucket {0}' -f $BucketName) -Detail '已存在'
            return $true
        }
    }

    $listResult = Invoke-ExternalCommand `
        -FilePath 'scoop' `
        -Arguments @('bucket', 'list') `
        -Quiet

    if ($listResult.Success) {
        $existingBuckets = @()

        if (-not [string]::IsNullOrWhiteSpace($listResult.Output)) {
            $existingBuckets = $listResult.Output `
                -split "(`r`n|`n|`r|\s+)" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }

        foreach ($bucket in $existingBuckets) {
            if ([string]::Equals($bucket.Trim(), $BucketName, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Info ('Bucket 已存在，跳过添加：{0}' -f $BucketName)
                Add-SummaryItem -Category 'Skipped' -Name ('Scoop bucket {0}' -f $BucketName) -Detail '已存在'
                return $true
            }
        }
    } else {
        Write-Warn '读取 Scoop bucket 列表失败，将尝试直接添加。'
    }

    $result = Invoke-ExternalCommand `
        -FilePath 'scoop' `
        -Arguments @('bucket', 'add', $BucketName)

    if ($result.Success) {
        Write-Info ('Bucket 添加成功：{0}' -f $BucketName)
        Add-SummaryItem -Category 'Installed' -Name ('Scoop bucket {0}' -f $BucketName) -Detail '添加成功'
        return $true
    }

    if ($result.Output -match '(?i)already\s+exists') {
        Write-Info ('Bucket 已存在，跳过添加：{0}' -f $BucketName)
        Add-SummaryItem -Category 'Skipped' -Name ('Scoop bucket {0}' -f $BucketName) -Detail '已存在'
        return $true
    }

    Add-SummaryItem -Category 'Failed' -Name ('Scoop bucket {0}' -f $BucketName) -Detail '添加失败'
    Write-ErrorMessage ('添加 bucket 失败：{0}，退出码：{1}' -f $BucketName, $result.ExitCode)
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) { Write-Warn $result.Output }
    return $false
}

function Configure-Git {
    Write-Step '配置 Git'
    $sslResult = Invoke-ExternalCommand -FilePath 'git' -Arguments @('config', '--global', 'http.sslVerify', 'false') -FailureMessage '配置 git http.sslVerify 失败'
    if ($sslResult.Success) { Write-Info '已配置 git config --global http.sslVerify false。' }
    $name = Read-TrimmedInput '请输入 Git 用户名，直接回车跳过'
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $nameResult = Invoke-ExternalCommand -FilePath 'git' -Arguments @('config', '--global', 'user.name', $name) -FailureMessage '配置 Git 用户名失败'
        if ($nameResult.Success) { $script:Summary.GitUserNameConfigured = $true; Write-Info 'Git 用户名已配置。' }
    } else { Write-Info '未配置 Git 用户名。' }
    $email = Read-TrimmedInput '请输入 Git 邮箱，直接回车跳过'
    if (-not [string]::IsNullOrWhiteSpace($email)) {
        $emailResult = Invoke-ExternalCommand -FilePath 'git' -Arguments @('config', '--global', 'user.email', $email) -FailureMessage '配置 Git 邮箱失败'
        if ($emailResult.Success) { $script:Summary.GitUserEmailConfigured = $true; Write-Info 'Git 邮箱已配置。' }
    } else { Write-Info '未配置 Git 邮箱。' }
}

function Install-Git {
    Write-Step '安装 Git'
    $ok = Install-ScoopPackage -PackageName 'git' -DisplayName 'Git' -CommandName 'git'
    if (-not $ok) { Write-ErrorMessage 'Git 是后续 bucket 和部分安装流程的关键依赖。'; return $false }
    if (-not (Test-CommandExists 'git')) {
        Write-ErrorMessage 'Git 安装后仍不可用。'
        Add-SummaryItem -Category 'Failed' -Name 'Git' -Detail 'git 命令不可用'
        return $false
    }
    Configure-Git
    Write-Step '添加 Scoop buckets'
    Add-ScoopBucket -BucketName 'main' | Out-Null
    Add-ScoopBucket -BucketName 'java' | Out-Null
    Add-ScoopBucket -BucketName 'versions' | Out-Null
    return $true
}

function Configure-PnpmEnvironment {
    param([string]$DevRoot)

    $pnpmHome = Join-Path (Join-Path $DevRoot 'apps') 'pnpm'
    $pnpmStore = Join-Path (Join-Path $DevRoot 'caches') 'pnpm-store'
    if (-not (Test-Path -LiteralPath $pnpmHome)) { New-Item -ItemType Directory -Path $pnpmHome -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $pnpmStore)) { New-Item -ItemType Directory -Path $pnpmStore -Force | Out-Null }

    Set-UserEnvironmentVariable -Name 'PNPM_HOME' -Value $pnpmHome | Out-Null
    Add-PathEntry -PathEntry $pnpmHome
    $env:NPM_CONFIG_GLOBAL_BIN_DIR = $pnpmHome
    $script:Summary.Paths['PnpmHome'] = $pnpmHome
    $script:Summary.Paths['PnpmStore'] = $pnpmStore

    if (-not (Test-CommandExists 'pnpm')) {
        Write-Warn 'pnpm 命令不可用，跳过 pnpm 配置。'
        return
    }

    $binResult = Invoke-ExternalCommand -FilePath 'pnpm' -Arguments @('config', 'set', 'global-bin-dir', $pnpmHome, '--global') -FailureMessage '配置 pnpm global-bin-dir 失败'
    if (-not $binResult.Success) { Add-SummaryItem -Category 'Failed' -Name 'pnpm global-bin-dir' -Detail '配置失败'; return }

    $storeResult = Invoke-ExternalCommand -FilePath 'pnpm' -Arguments @('config', 'set', 'store-dir', $pnpmStore, '--global') -FailureMessage '配置 pnpm store-dir 失败'
    if (-not $storeResult.Success) { Add-SummaryItem -Category 'Failed' -Name 'pnpm store-dir' -Detail '配置失败' }
}

function Install-Volta {
    param([string]$DevRoot)
    Write-Step '配置 Volta、Node.js 与 pnpm'
    $voltaHome = Join-Path (Join-Path $DevRoot 'apps') 'volta'
    if (-not (Test-Path -LiteralPath $voltaHome)) { New-Item -ItemType Directory -Path $voltaHome -Force | Out-Null }
    $voltaBin = Join-Path $voltaHome 'bin'
    if (-not (Test-Path -LiteralPath $voltaBin)) { New-Item -ItemType Directory -Path $voltaBin -Force | Out-Null }
    Set-UserEnvironmentVariable -Name 'VOLTA_HOME' -Value $voltaHome | Out-Null
    Add-PathEntry -PathEntry $voltaBin
    $script:Summary.Paths['VoltaHome'] = $voltaHome
    $ok = Install-ScoopPackage -PackageName 'volta' -DisplayName 'Volta' -CommandName 'volta'
    if (-not $ok -or -not (Test-CommandExists 'volta')) { Add-SummaryItem -Category 'Failed' -Name 'Volta' -Detail 'volta 命令不可用'; return }
    if (-not (Invoke-ExternalCommand -FilePath 'volta' -Arguments @('install', 'node@20') -FailureMessage 'Volta 安装 Node.js 20 失败').Success) { Add-SummaryItem -Category 'Failed' -Name 'Node.js' -Detail 'volta install node@20 失败' }
    if (-not (Invoke-ExternalCommand -FilePath 'volta' -Arguments @('install', 'pnpm') -FailureMessage 'Volta 安装 pnpm 失败').Success) { Add-SummaryItem -Category 'Failed' -Name 'pnpm' -Detail 'volta install pnpm 失败' }
    $npmCache = Join-Path (Join-Path $DevRoot 'caches') 'npm'
    if (Test-CommandExists 'npm') { Invoke-ExternalCommand -FilePath 'npm' -Arguments @('config', 'set', 'cache', $npmCache, '--global') -FailureMessage '配置 npm cache 失败' | Out-Null } else { Write-Warn 'npm 命令不可用，跳过 npm cache 配置。' }
    Configure-PnpmEnvironment -DevRoot $DevRoot
    if (Test-CommandExists 'node') { $script:Summary.Versions['Node'] = Get-CommandText -FilePath 'node' -Arguments @('--version') }
    if (Test-CommandExists 'npm') { $script:Summary.Versions['npm'] = Get-CommandText -FilePath 'npm' -Arguments @('--version') }
    if (Test-CommandExists 'pnpm') { $script:Summary.Versions['pnpm'] = Get-CommandText -FilePath 'pnpm' -Arguments @('--version') }
    if (Test-CommandExists 'volta') { $script:Summary.Versions['Volta'] = Get-CommandText -FilePath 'volta' -Arguments @('--version') }
}

function Resolve-JavaScoopPackages {
    param([string]$Version)
    switch ($Version) {
        '8' { return @('temurin8-jdk', 'zulu8-jdk') }
        '11' { return @('temurin11-jdk', 'microsoft11-jdk', 'openjdk11') }
        '17' { return @('temurin17-jdk', 'microsoft17-jdk', 'openjdk17') }
        '21' { return @('temurin21-jdk', 'microsoft21-jdk', 'openjdk21') }
        default { return @(('temurin{0}-jdk' -f $Version), ('openjdk{0}' -f $Version)) }
    }
}

function Install-FirstScoopPackage {
    param([string[]]$PackageNames, [string]$DisplayName, [string]$CommandName)
    foreach ($packageName in $PackageNames) {
        if (Test-ScoopPackageInstalled -PackageName $packageName) {
            Write-Info ('{0} 已安装：{1}' -f $DisplayName, $packageName)
            Add-SummaryItem -Category 'Skipped' -Name $DisplayName -Detail ('Scoop 包已存在：{0}' -f $packageName)
            return $packageName
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($CommandName) -and (Test-CommandExists $CommandName)) {
        Write-Warn ('检测到命令 {0} 已存在，跳过 Scoop 安装 {1}。' -f $CommandName, $DisplayName)
        Add-SummaryItem -Category 'Skipped' -Name $DisplayName -Detail ('命令 {0} 已存在' -f $CommandName)
        return ''
    }
    foreach ($packageName in $PackageNames) {
        Write-Info ('正在尝试安装 {0}：{1}' -f $DisplayName, $packageName)
        $result = Invoke-ExternalCommand -FilePath 'scoop' -Arguments @('install', $packageName) -FailureMessage ('安装 {0} 失败：{1}' -f $DisplayName, $packageName)
        if ($result.Success) { Add-SummaryItem -Category 'Installed' -Name $DisplayName -Detail $packageName; return $packageName }
    }
    Add-SummaryItem -Category 'Failed' -Name $DisplayName -Detail ('候选包均安装失败：{0}' -f ($PackageNames -join ', '))
    return $null
}

function Install-Java {
    param([string]$DevRoot)
    Write-Step '安装 JDK'
    $javaVersion = Read-TrimmedInput '请输入 Java 版本，支持 8、11、17、21，直接回车默认 11'
    if ([string]::IsNullOrWhiteSpace($javaVersion)) { $javaVersion = '11' }
    $installedPackage = Install-FirstScoopPackage -PackageNames (Resolve-JavaScoopPackages -Version $javaVersion) -DisplayName ('Java {0}' -f $javaVersion) -CommandName 'java'
    if ($null -eq $installedPackage) { return }
    $javaHome = ''
    if (-not [string]::IsNullOrWhiteSpace($installedPackage)) {
        $prefixResult = Invoke-ExternalCommand -FilePath 'scoop' -Arguments @('prefix', $installedPackage) -Quiet
        if ($prefixResult.Success) { $javaHome = $prefixResult.Output.Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($javaHome) -and (Test-CommandExists 'java')) {
        $javaCommand = Get-Command 'java' -ErrorAction SilentlyContinue
        if ($null -ne $javaCommand) { $javaHome = Split-Path -Parent (Split-Path -Parent $javaCommand.Source) }
    }
    if (-not [string]::IsNullOrWhiteSpace($javaHome) -and (Test-Path -LiteralPath $javaHome)) {
        Set-UserEnvironmentVariable -Name 'JAVA_HOME' -Value $javaHome | Out-Null
        Add-PathEntry -PathEntry (Join-Path $javaHome 'bin')
        $script:Summary.Paths['JAVA_HOME'] = $javaHome
    } else { Write-Warn '未能自动解析 JAVA_HOME。' }
    if (Test-CommandExists 'java') { $script:Summary.Versions['Java'] = Get-CommandText -FilePath 'java' -Arguments @('-version'); Write-Info $script:Summary.Versions['Java'] }
}

function Write-MavenSettings {
    param([string]$SettingsPath, [string]$LocalRepository)
    try {
        $settingsDirectory = Split-Path -Parent $SettingsPath
        if (-not (Test-Path -LiteralPath $settingsDirectory)) { New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $LocalRepository)) { New-Item -ItemType Directory -Path $LocalRepository -Force | Out-Null }
        $escapedRepository = [Security.SecurityElement]::Escape($LocalRepository)
        $xml = @"
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <localRepository>$escapedRepository</localRepository>
</settings>
"@
        Set-Content -Path $SettingsPath -Value $xml -Encoding UTF8
        Write-Info ('Maven settings.xml 已写入：{0}' -f $SettingsPath)
        return $true
    } catch {
        Write-ErrorMessage ('写入 Maven settings.xml 失败：{0}' -f $_.Exception.Message)
        return $false
    }
}

function Install-Maven {
    param([string]$DevRoot)
    Write-Step '配置 Maven'
    $ok = Install-ScoopPackage -PackageName 'maven' -DisplayName 'Maven' -CommandName 'mvn'
    if (-not $ok) { return }
    $mavenRepository = Join-Path (Join-Path $DevRoot 'caches') 'maven-repository'
    $mavenSettings = Join-Path (Join-Path (Join-Path $DevRoot 'configs') 'maven') 'settings.xml'
    Write-MavenSettings -SettingsPath $mavenSettings -LocalRepository $mavenRepository | Out-Null
    Set-UserEnvironmentVariable -Name 'MAVEN_USER_HOME' -Value (Split-Path -Parent $mavenSettings) | Out-Null
    Set-UserEnvironmentVariable -Name 'MAVEN_OPTS' -Value ('-Dmaven.repo.local="{0}"' -f $mavenRepository) | Out-Null
    $script:Summary.Paths['MavenRepository'] = $mavenRepository
    $script:Summary.Paths['MavenSettings'] = $mavenSettings
    if (Test-CommandExists 'mvn') {
        $script:Summary.Versions['Maven'] = Get-CommandText -FilePath 'mvn' -Arguments @('-version')
        Write-Info $script:Summary.Versions['Maven']
    }
}

function Resolve-PythonScoopPackages {
    param([string]$Version)
    switch ($Version) {
        '3.12' { return @('python312', 'python') }
        '3.11' { return @('python311') }
        '3.10' { return @('python310') }
        '3.9' { return @('python39') }
        default { return @(('python{0}' -f $Version.Replace('.', '')), 'python') }
    }
}

function Install-Python {
    param([string]$DevRoot)
    Write-Step '安装 Python 与 uv'
    $pythonVersion = Read-TrimmedInput '请输入 Python 版本，例如 3.12；直接回车默认 3.12'
    if ([string]::IsNullOrWhiteSpace($pythonVersion)) { $pythonVersion = '3.12' }
    $installedPackage = Install-FirstScoopPackage -PackageNames (Resolve-PythonScoopPackages -Version $pythonVersion) -DisplayName ('Python {0}' -f $pythonVersion) -CommandName 'python'
    if ($null -eq $installedPackage) { return }
    $pipCache = Join-Path (Join-Path $DevRoot 'caches') 'pip'
    $uvCache = Join-Path (Join-Path $DevRoot 'caches') 'uv'
    Set-UserEnvironmentVariable -Name 'PIP_CACHE_DIR' -Value $pipCache | Out-Null
    Set-UserEnvironmentVariable -Name 'UV_CACHE_DIR' -Value $uvCache | Out-Null
    if (Test-CommandExists 'python') {
        Invoke-ExternalCommand -FilePath 'python' -Arguments @('-m', 'pip', 'config', 'set', 'global.cache-dir', $pipCache) -FailureMessage '配置 pip cache 失败' | Out-Null
        $script:Summary.Versions['Python'] = Get-CommandText -FilePath 'python' -Arguments @('--version')
        $script:Summary.Versions['pip'] = Get-CommandText -FilePath 'python' -Arguments @('-m', 'pip', '--version')
    } else { Write-Warn 'python 命令不可用，跳过 pip cache 配置。' }
    $uvOk = Install-ScoopPackage -PackageName 'uv' -DisplayName 'uv' -CommandName 'uv'
    if ($uvOk -and (Test-CommandExists 'uv')) { $script:Summary.Versions['uv'] = Get-CommandText -FilePath 'uv' -Arguments @('--version') }
}

function Configure-GoEnvironment {
    param([string]$DevRoot)

    $goPath = Join-Path (Join-Path $DevRoot 'apps') 'go'
    $goBin = Join-Path $goPath 'bin'
    $goBuildCache = Join-Path (Join-Path $DevRoot 'caches') 'go-build'
    $goModCache = Join-Path (Join-Path $DevRoot 'caches') 'go-mod'

    foreach ($directory in @($goPath, $goBin, $goBuildCache, $goModCache)) {
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }

    Set-UserEnvironmentVariable -Name 'GOPATH' -Value $goPath | Out-Null
    Set-UserEnvironmentVariable -Name 'GOBIN' -Value $goBin | Out-Null
    Set-UserEnvironmentVariable -Name 'GOCACHE' -Value $goBuildCache | Out-Null
    Set-UserEnvironmentVariable -Name 'GOMODCACHE' -Value $goModCache | Out-Null
    Add-PathEntry -PathEntry $goBin

    $script:Summary.Paths['GoPath'] = $goPath
    $script:Summary.Paths['GoBin'] = $goBin
    $script:Summary.Paths['GoBuildCache'] = $goBuildCache
    $script:Summary.Paths['GoModCache'] = $goModCache

    if (-not (Test-CommandExists 'go')) {
        Write-Warn 'go 命令不可用，跳过 go env 配置。'
        return
    }

    Invoke-ExternalCommand -FilePath 'go' -Arguments @('env', '-w', 'GOPROXY=https://goproxy.cn,direct') -FailureMessage '配置 GOPROXY 失败' | Out-Null
    Invoke-ExternalCommand -FilePath 'go' -Arguments @('env', '-w', ('GOPATH={0}' -f $goPath)) -FailureMessage '配置 GOPATH 失败' | Out-Null
    Invoke-ExternalCommand -FilePath 'go' -Arguments @('env', '-w', ('GOBIN={0}' -f $goBin)) -FailureMessage '配置 GOBIN 失败' | Out-Null
    Invoke-ExternalCommand -FilePath 'go' -Arguments @('env', '-w', ('GOCACHE={0}' -f $goBuildCache)) -FailureMessage '配置 GOCACHE 失败' | Out-Null
    Invoke-ExternalCommand -FilePath 'go' -Arguments @('env', '-w', ('GOMODCACHE={0}' -f $goModCache)) -FailureMessage '配置 GOMODCACHE 失败' | Out-Null
    $script:Summary.Versions['Go'] = Get-CommandText -FilePath 'go' -Arguments @('version')
}

function Install-Go {
    Write-Step '安装 Go'
    return (Install-ScoopPackage -PackageName 'go' -DisplayName 'Go' -CommandName 'go')
}

function Write-SummaryList {
    param([string]$Title, [object[]]$Items)
    Write-Host $Title -ForegroundColor White
    if ($null -eq $Items -or $Items.Count -eq 0) { Write-Host '  无'; return }
    foreach ($item in $Items) { Write-Host ('  - {0}' -f $item) }
}

function Write-Summary {
    Write-Step '安装摘要'
    Write-Host ('开发根目录：{0}' -f $script:Summary.Paths['DevRoot'])
    Write-Host ('Scoop 路径：{0}' -f $script:Summary.Paths['Scoop'])
    Write-Host ('Scoop proxy：{0}' -f $script:Summary.ScoopProxy)
    Write-Host ''
    Write-SummaryList -Title '已安装：' -Items $script:Summary.Installed
    Write-SummaryList -Title '已跳过：' -Items $script:Summary.Skipped
    Write-SummaryList -Title '失败：' -Items $script:Summary.Failed
    Write-Host ''
    Write-Host '关键路径：' -ForegroundColor White
    foreach ($key in $script:Summary.Paths.Keys) { Write-Host ('  - {0}: {1}' -f $key, $script:Summary.Paths[$key]) }
    Write-Host ''
    Write-Host 'Git 配置状态：' -ForegroundColor White
    if ($script:Summary.GitUserNameConfigured) { $gitNameStatus = '已配置' } else { $gitNameStatus = '未配置或未修改' }
    if ($script:Summary.GitUserEmailConfigured) { $gitEmailStatus = '已配置' } else { $gitEmailStatus = '未配置或未修改' }
    Write-Host ('  - 用户名：{0}' -f $gitNameStatus)
    Write-Host ('  - 邮箱：{0}' -f $gitEmailStatus)
    Write-Host ''
    Write-Host '版本信息：' -ForegroundColor White
    if ($script:Summary.Versions.Keys.Count -eq 0) {
        Write-Host '  无'
    } else {
        foreach ($key in $script:Summary.Versions.Keys) { Write-Host ('  - {0}: {1}' -f $key, $script:Summary.Versions[$key]) }
    }
}

function Install-NodeDevSuite {
    param([string]$DevRoot)

    Write-Step '安装 node开发套件（volta + node + npm + pnpm）'
    Install-Volta -DevRoot $DevRoot
}

function Install-JavaDevSuite {
    param([string]$DevRoot)

    Write-Step '安装 Java开发套件（jdk + maven）'
    Install-Java -DevRoot $DevRoot
    Install-Maven -DevRoot $DevRoot
}

function Install-PythonDevSuite {
    param([string]$DevRoot)

    Write-Step '安装 Python开发套件（python + uv）'
    Install-Python -DevRoot $DevRoot
}

function Install-GoDevSuite {
    param([string]$DevRoot)

    Write-Step '安装 Go开发套件（go）'
    if (Install-Go) { Configure-GoEnvironment -DevRoot $DevRoot }
}

function Install-SelectedSuites {
    param(
        [string[]]$Selection,
        [string]$DevRoot
    )

    if ($Selection -contains 'node-suite') { Install-NodeDevSuite -DevRoot $DevRoot }
    if ($Selection -contains 'java-suite') { Install-JavaDevSuite -DevRoot $DevRoot }
    if ($Selection -contains 'python-suite') { Install-PythonDevSuite -DevRoot $DevRoot }
    if ($Selection -contains 'go-suite') { Install-GoDevSuite -DevRoot $DevRoot }
}

function Start-WindowsDevEnvironmentSetup {
    Test-InitialEnvironment
    $devRoot = Read-DevRoot
    $scoopProxy = Read-ScoopProxy
    $selection = Read-InstallSelection
    if (-not (Confirm-InstallSelection -Selection $selection)) { Write-Warn '用户取消安装。'; return }
    $scoopReady = Install-Scoop -DevRoot $devRoot
    if (-not $scoopReady) {
        Write-ErrorMessage 'Scoop 不可用，无法继续通过 Scoop 安装开发工具。'
        Write-Summary
        return
    }
    Set-ScoopProxy -Proxy $scoopProxy
    $gitReady = Install-Git
    if (-not $gitReady) {
        Write-ErrorMessage 'Git 不可用，后续 Scoop bucket 和工具安装可能失败；脚本将停止后续工具安装。'
        Write-Summary
        return
    }
    Install-SelectedSuites -Selection $selection -DevRoot $devRoot
    Write-Summary
}

Start-WindowsDevEnvironmentSetup
