<#
.SYNOPSIS
    Честное сравнение производительности Quarkus и Spring Boot
.DESCRIPTION
    Запускает оба приложения одновременно, измеряет время запуска и потребление памяти до и после запросов,
    выполняет тестовые запросы и завершает процессы.
#>

# --- Конфигурация ---
$QuarkusPath = "C:\Projects\ws_IBS\qrk_001\qrk_001_quarkus\target\quarkus-app"
$SpringPath = "C:\Projects\ws_IBS\qrk_001\qrk_001_spring\target"

$QuarkusJar = "quarkus-run.jar"
$SpringJar = "qrk_001_spring-0.0.1-SNAPSHOT.jar"

$QuarkusPort = 8080
$SpringPort = 8081

$QuarkusMaxMem = "128m"
$SpringMaxMem = "128m"

$TestEndpoint = "/hello"
$RequestsCount = 5

# --- Функции ---
function Log-Start { param([string]$Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan }
function Log-Success { param([string]$Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Green }
function Log-Error { param([string]$Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Red }

function Clear-Ports {
    Log-Start "Проверка занятых портов..."
    $ports = @(8080, 8081)
    foreach ($port in $ports) {
        $connection = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        if ($connection) {
            $procId = $connection.OwningProcess
            try {
                $process = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($process) {
                    Log-Start "Завершение процесса $($process.ProcessName) (PID: $procId), занимающего порт $port"
                    Stop-Process -Id $procId -Force
                }
            } catch {
                Log-Error "Не удалось завершить процесс $procId"
            }
        }
    }
    Start-Sleep -Seconds 1
    Log-Success "Порты очищены"
}

function Get-ProcessMemory {
    param([string]$ProcessName)
    $process = Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "java.exe" -and $_.CommandLine -like "*$ProcessName*"
    } | Select-Object -First 1
    if ($process) { return [math]::round($process.WorkingSetSize / 1MB, 2) }
    return $null
}

function Wait-For-Server {
    param([string]$Url, [int]$TimeoutSeconds = 30)
    $startTime = Get-Date
    while ($true) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -eq 200) { return $true }
        } catch { }
        if ((Get-Date) - $startTime -gt (New-TimeSpan -Seconds $TimeoutSeconds)) { return $false }
        Start-Sleep -Milliseconds 500
    }
}

function Start-App {
    param([string]$Name, [string]$Path, [string]$JarFile, [int]$Port, [string]$MaxMem, [string]$LogFile)
    $existingProcess = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($existingProcess) {
        Log-Error "Порт $Port уже занят."
        return $null
    }
    Log-Start "Запуск $Name..."
    $process = Start-Process -FilePath "java" -ArgumentList "-Xmx$MaxMem -jar $JarFile" -WorkingDirectory $Path -PassThru -NoNewWindow -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err"
    return $process
}

function Test-Endpoint {
    param([string]$Name, [int]$Port)
    $url = "http://localhost:$Port$TestEndpoint"
    try {
        $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 5
        return $response.Content
    } catch {
        Log-Error "$Name не ответил: $($_.Exception.Message)"
        return $null
    }
}

function Show-Results {
    param(
        $QuarkusData, $SpringData,
        $QuarkusResponse, $SpringResponse,
        $QuarkusMemBefore, $SpringMemBefore,
        $QuarkusMemAfter, $SpringMemAfter
    )
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Magenta
    Write-Host "   СРАВНЕНИЕ ПРОИЗВОДИТЕЛЬНОСТИ" -ForegroundColor Magenta
    Write-Host "   Quarkus vs Spring Boot" -ForegroundColor Magenta
    Write-Host "==========================================" -ForegroundColor Magenta
    Write-Host ""
    if ($QuarkusData -and $SpringData) {
        Write-Host "ПАРАМЕТРЫ ЗАПУСКА (запущены одновременно):" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Quarkus:  Время: $($QuarkusData.StartupTime) мс | Память после старта: $($QuarkusData.MemoryMB) МБ" -ForegroundColor Green
        Write-Host "  Spring:   Время: $($SpringData.StartupTime) мс | Память после старта: $($SpringData.MemoryMB) МБ" -ForegroundColor Green
        Write-Host ""

        if ($QuarkusData.StartupTime -lt $SpringData.StartupTime) {
            $diffMs = $SpringData.StartupTime - $QuarkusData.StartupTime
            $timesFaster = [math]::round($SpringData.StartupTime / $QuarkusData.StartupTime, 2)
            $percentFaster = [math]::round(($diffMs / $SpringData.StartupTime) * 100, 1)
            Write-Host "✅ Приложение Quarkus запускается быстрее Spring в $timesFaster раза (на $percentFaster%)" -ForegroundColor Green
        } else {
            $diffMs = $QuarkusData.StartupTime - $SpringData.StartupTime
            $timesSlower = [math]::round($QuarkusData.StartupTime / $SpringData.StartupTime, 2)
            $percentSlower = [math]::round(($diffMs / $QuarkusData.StartupTime) * 100, 1)
            Write-Host "⚠️ Приложение Spring запускается быстрее Quarkus в $timesSlower раза (на $percentSlower%)" -ForegroundColor Yellow
        }

        if ($QuarkusData.MemoryMB -and $SpringData.MemoryMB) {
            if ($QuarkusData.MemoryMB -lt $SpringData.MemoryMB) {
                $diffMem = [math]::round($SpringData.MemoryMB - $QuarkusData.MemoryMB, 2)
                $timesLess = [math]::round($SpringData.MemoryMB / $QuarkusData.MemoryMB, 2)
                $percentLess = [math]::round(($diffMem / $SpringData.MemoryMB) * 100, 1)
                Write-Host "✅ Приложение Quarkus потребляет в $timesLess раза меньше памяти (на $percentLess%)" -ForegroundColor Green
            } else {
                $diffMem = [math]::round($QuarkusData.MemoryMB - $SpringData.MemoryMB, 2)
                $timesLess = [math]::round($QuarkusData.MemoryMB / $SpringData.MemoryMB, 2)
                $percentLess = [math]::round(($diffMem / $QuarkusData.MemoryMB) * 100, 1)
                Write-Host "⚠️ Приложение Spring потребляет в $timesLess раза меньше памяти (на $percentLess%)" -ForegroundColor Yellow
            }
        }
        Write-Host ""

        # Память до и после запросов
        Write-Host "ПАМЯТЬ ДО И ПОСЛЕ ЗАПРОСОВ ($RequestsCount запросов):" -ForegroundColor Yellow
        Write-Host ""
        $quarkusMemBeforeStr = if ($QuarkusMemBefore) { "$QuarkusMemBefore МБ" } else { "N/A" }
        $quarkusMemAfterStr = if ($QuarkusMemAfter) { "$QuarkusMemAfter МБ" } else { "N/A" }
        $springMemBeforeStr = if ($SpringMemBefore) { "$SpringMemBefore МБ" } else { "N/A" }
        $springMemAfterStr = if ($SpringMemAfter) { "$SpringMemAfter МБ" } else { "N/A" }

        Write-Host "  Quarkus:  до запросов: $quarkusMemBeforeStr | после запросов: $quarkusMemAfterStr" -ForegroundColor Green
        Write-Host "  Spring:   до запросов: $springMemBeforeStr | после запросов: $springMemAfterStr" -ForegroundColor Green
        Write-Host ""

        if ($QuarkusMemBefore -and $QuarkusMemAfter) {
            $diff = [math]::round($QuarkusMemAfter - $QuarkusMemBefore, 2)
            if ($diff -gt 0) {
                Write-Host "  Quarkus: память выросла на $diff МБ" -ForegroundColor Yellow
            } elseif ($diff -lt 0) {
                $diffAbs = [math]::abs($diff)
                $percentChange = [math]::round(($diffAbs / $QuarkusMemBefore) * 100, 1)
                Write-Host "  Quarkus: память уменьшилась на $diffAbs МБ (на $percentChange%)" -ForegroundColor Yellow
            } else {
                Write-Host "  Quarkus: память не изменилась" -ForegroundColor Yellow
            }
        }
        if ($SpringMemBefore -and $SpringMemAfter) {
            $diff = [math]::round($SpringMemAfter - $SpringMemBefore, 2)
            if ($diff -gt 0) {
                Write-Host "  Spring:  память выросла на $diff МБ" -ForegroundColor Yellow
            } elseif ($diff -lt 0) {
                $diffAbs = [math]::abs($diff)
                $percentChange = [math]::round(($diffAbs / $SpringMemBefore) * 100, 1)
                Write-Host "  Spring:  память уменьшилась на $diffAbs МБ (на $percentChange%)" -ForegroundColor Yellow
            } else {
                Write-Host "  Spring:  память не изменилась" -ForegroundColor Yellow
            }
        }
        Write-Host ""

        # Сравнение памяти после запросов
        if ($QuarkusMemAfter -and $SpringMemAfter) {
            if ($QuarkusMemAfter -lt $SpringMemAfter) {
                $diffMemAfter = [math]::round($SpringMemAfter - $QuarkusMemAfter, 2)
                $timesLessAfter = [math]::round($SpringMemAfter / $QuarkusMemAfter, 2)
                $percentLessAfter = [math]::round(($diffMemAfter / $SpringMemAfter) * 100, 1)
                Write-Host "✅ Приложение Quarkus после запросов потребляет в $timesLessAfter раза меньше памяти (на $percentLessAfter%)" -ForegroundColor Green
            } else {
                $diffMemAfter = [math]::round($QuarkusMemAfter - $SpringMemAfter, 2)
                $timesLessAfter = [math]::round($QuarkusMemAfter / $SpringMemAfter, 2)
                $percentLessAfter = [math]::round(($diffMemAfter / $QuarkusMemAfter) * 100, 1)
                Write-Host "⚠️ Приложение Spring после запросов потребляет в $timesLessAfter раза меньше памяти (на $percentLessAfter%)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
    }
    Write-Host "ОТВЕТЫ СЕРВЕРОВ:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Quarkus: $QuarkusResponse" -ForegroundColor Green
    Write-Host "  Spring:  $SpringResponse" -ForegroundColor Green
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Magenta
    Write-Host "Приложения запущены. Для остановки нажмите Enter..." -ForegroundColor Cyan
}

function Stop-Applications {
    param($QuarkusProcess, $SpringProcess)
    Log-Start "Остановка приложений..."
    if ($QuarkusProcess -and -not $QuarkusProcess.HasExited) { $QuarkusProcess.Kill(); Log-Success "Quarkus остановлен" }
    if ($SpringProcess -and -not $SpringProcess.HasExited) { $SpringProcess.Kill(); Log-Success "Spring остановлен" }
    Get-Process -Name java -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowTitle -like "*quarkus*" -or $_.MainWindowTitle -like "*spring*"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Log-Success "Все процессы завершены"
}

# --- Основной сценарий ---
function Main {
    $quarkusProcess = $null; $springProcess = $null
    $quarkusData = $null; $springData = $null
    $quarkusResponse = $null; $springResponse = $null
    $quarkusMemBefore = $null; $springMemBefore = $null
    $quarkusMemAfter = $null; $springMemAfter = $null

    try {
        Clear-Ports
        $logDir = Join-Path $PSScriptRoot "logs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $quarkusLog = Join-Path $logDir "quarkus.log"
        $springLog = Join-Path $logDir "spring.log"

        Log-Start "Запуск приложений одновременно..."
        $quarkusProcess = Start-App -Name "Quarkus" -Path $QuarkusPath -JarFile $QuarkusJar -Port $QuarkusPort -MaxMem $QuarkusMaxMem -LogFile $quarkusLog
        $springProcess = Start-App -Name "Spring Boot" -Path $SpringPath -JarFile $SpringJar -Port $SpringPort -MaxMem $SpringMaxMem -LogFile $springLog

        if (-not $quarkusProcess -or -not $springProcess) {
            Log-Error "Не удалось запустить одно из приложений"
            return
        }

        Log-Start "Измерение времени старта и памяти..."

        $quarkusStartTime = Get-Date
        $quarkusReady = Wait-For-Server -Url "http://localhost:$QuarkusPort$TestEndpoint"
        $quarkusEndTime = Get-Date

        $springStartTime = Get-Date
        $springReady = Wait-For-Server -Url "http://localhost:$SpringPort$TestEndpoint"
        $springEndTime = Get-Date

        if ($quarkusReady) {
            $quarkusStartupTime = [math]::round(($quarkusEndTime - $quarkusStartTime).TotalMilliseconds, 2)
            $quarkusMemory = Get-ProcessMemory -ProcessName "quarkus"
            $quarkusData = @{ Process = $quarkusProcess; StartupTime = $quarkusStartupTime; MemoryMB = $quarkusMemory; Port = $QuarkusPort; Name = "Quarkus" }
            Log-Success "Quarkus запущен за $quarkusStartupTime мс, память: $($quarkusMemory) МБ"
        } else { Log-Error "Quarkus не запустился за отведённое время" }

        if ($springReady) {
            $springStartupTime = [math]::round(($springEndTime - $springStartTime).TotalMilliseconds, 2)
            $springMemory = Get-ProcessMemory -ProcessName "spring"
            $springData = @{ Process = $springProcess; StartupTime = $springStartupTime; MemoryMB = $springMemory; Port = $SpringPort; Name = "Spring Boot" }
            Log-Success "Spring Boot запущен за $springStartupTime мс, память: $($springMemory) МБ"
        } else { Log-Error "Spring Boot не запустился за отведённое время" }

        # Память до запросов
        $quarkusMemBefore = Get-ProcessMemory -ProcessName "quarkus"
        $springMemBefore = Get-ProcessMemory -ProcessName "spring"
        Log-Start "Память до запросов: Quarkus = $quarkusMemBefore МБ, Spring = $springMemBefore МБ"

        # Выполнение запросов
        Log-Start "Выполнение $RequestsCount запросов к каждому серверу..."
        for ($i = 1; $i -le $RequestsCount; $i++) {
            if ($quarkusData) {
                $quarkusResponse = Test-Endpoint -Name "Quarkus" -Port $QuarkusPort
            }
            if ($springData) {
                $springResponse = Test-Endpoint -Name "Spring Boot" -Port $SpringPort
            }
            Start-Sleep -Milliseconds 500
        }

        # Память после запросов
        $quarkusMemAfter = Get-ProcessMemory -ProcessName "quarkus"
        $springMemAfter = Get-ProcessMemory -ProcessName "spring"
        Log-Start "Память после запросов: Quarkus = $quarkusMemAfter МБ, Spring = $springMemAfter МБ"

        Show-Results -QuarkusData $quarkusData -SpringData $springData -QuarkusResponse $quarkusResponse -SpringResponse $springResponse -QuarkusMemBefore $quarkusMemBefore -SpringMemBefore $springMemBefore -QuarkusMemAfter $quarkusMemAfter -SpringMemAfter $springMemAfter
        Read-Host
        Stop-Applications -QuarkusProcess $quarkusProcess -SpringProcess $springProcess

    } catch {
        Log-Error "Ошибка: $($_.Exception.Message)"
        Stop-Applications -QuarkusProcess $quarkusProcess -SpringProcess $springProcess
    }
}

# --- Запуск ---
Main