#!/usr/bin/env pwsh

param(
    [string]$Config = "proxy-config.json",
    [Parameter(Position=0)]
    [string]$Command = "",
    [Parameter(Position=1, ValueFromRemainingArguments)]
    [string[]]$RemainingArgs = @()
)

# Set default config file
$ConfigFile = $Config

# Generate container name based on config file
$ConfigBasename = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile)
$ContainerName = "postgres-ssm-proxy_$ConfigBasename"

# Function to check if Docker is running
function Test-Docker {
    try {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: Docker is not running. Please start Docker first." -ForegroundColor Red
            exit 1
        }
    }
    catch {
        Write-Host "Error: Docker is not running. Please start Docker first." -ForegroundColor Red
        exit 1
    }
}

# Function to login to ECR and pull image
function Get-ECRImage {
    Write-Host "Logging in to ECR..."

    # Get ECR URI from config
    $configContent = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $ecrUri = $configContent.ecr.repository_uri
    $ecrRegistry = ($ecrUri -split '/')[0]

    # Set AWS environment variables
    $env:AWS_ACCESS_KEY_ID = $configContent.aws_credentials.access_key_id
    $env:AWS_SECRET_ACCESS_KEY = $configContent.aws_credentials.secret_access_key
    $env:AWS_REGION = if ($configContent.aws_region) { $configContent.aws_region } else { "eu-central-1" }

    # Login to ECR
    $loginPassword = aws ecr get-login-password --region $env:AWS_REGION 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to get ECR login password" -ForegroundColor Red
        exit 1
    }

    $loginPassword | docker login --username AWS --password-stdin $ecrRegistry 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to login to ECR" -ForegroundColor Red
        exit 1
    }

    Write-Host "Pulling Docker image from ECR..."
    docker pull "${ecrUri}:latest" 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Docker image pulled successfully from ECR" -ForegroundColor Green
        return "${ecrUri}:latest"
    }
    else {
        Write-Host "Error: Failed to pull Docker image from ECR" -ForegroundColor Red
        exit 1
    }
}

# Function to start proxy
function Start-Proxy {
    Test-Docker

    # Check if config exists
    if (!(Test-Path $ConfigFile)) {
        Write-Host "Error: Configuration file not found: $ConfigFile" -ForegroundColor Red
        Write-Host "Please create a configuration file or specify one with -Config"
        exit 1
    }

    # Read configuration
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $instanceId = $config.bastion.instance_id
    $rdsEndpoint = $config.rds.endpoint
    $awsAccessKeyId = $config.aws_credentials.access_key_id
    $awsSecretAccessKey = $config.aws_credentials.secret_access_key
    $awsRegion = if ($config.aws_region) { $config.aws_region } else { "eu-central-1" }
    $localPort = if ($config.local_port) { $config.local_port } else { 1337 }
    $dbUsername = $config.database.username
    $dbPassword = $config.database.password
    $dbName = $config.database.database
    $connectionString = $config.database.connection_string
    $ecrUri = $config.ecr.repository_uri

    # Export AWS credentials
    $env:AWS_ACCESS_KEY_ID = $awsAccessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $awsSecretAccessKey
    $env:AWS_REGION = $awsRegion

    # Check if container is already running
    $runningContainers = docker ps --format '{{.Names}}' 2>&1
    if ($runningContainers -contains $ContainerName) {
        Write-Host "Proxy is already running for config: $ConfigFile" -ForegroundColor Yellow
        Write-Host "To restart, run: .\proxy.ps1 -Config $ConfigFile restart"
        exit 0
    }

    # Check bastion instance status
    Write-Host "Checking bastion instance..."
    $instanceState = aws ec2 describe-instances `
        --instance-ids $instanceId `
        --region $awsRegion `
        --query 'Reservations[0].Instances[0].State.Name' `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        $instanceState = "not-found"
    }

    if ($instanceState -eq "stopped") {
        Write-Host "Starting bastion instance..."
        aws ec2 start-instances --instance-ids $instanceId --region $awsRegion 2>&1 | Out-Null
        Write-Host "Waiting for instance to be ready..."
        aws ec2 wait instance-status-ok --instance-ids $instanceId --region $awsRegion 2>&1 | Out-Null
    }
    elseif ($instanceState -ne "running") {
        Write-Host "Error: Bastion instance is in state: $instanceState" -ForegroundColor Red
        exit 1
    }

    # Pull image from ECR
    $imageName = Get-ECRImage

    # Remove any existing stopped container
    docker rm $ContainerName 2>&1 | Out-Null

    # Start container
    Write-Host "Starting proxy container..."

    $configFullPath = (Resolve-Path $ConfigFile).Path

    docker run -d `
        --name $ContainerName `
        --network host `
        -e AWS_ACCESS_KEY_ID="$awsAccessKeyId" `
        -e AWS_SECRET_ACCESS_KEY="$awsSecretAccessKey" `
        -e AWS_REGION="$awsRegion" `
        -v "${configFullPath}:/config/proxy-config.json:ro" `
        --restart unless-stopped `
        $imageName 2>&1 | Out-Null

    # Wait for container to start
    Start-Sleep -Seconds 2

    # Check if container is running
    $runningContainers = docker ps --format '{{.Names}}' 2>&1
    if ($runningContainers -contains $ContainerName) {
        Write-Host ""
        Write-Host "=== Proxy Started Successfully ===" -ForegroundColor Green
        Write-Host "Container: $ContainerName"
        Write-Host "Config: $ConfigFile"
        Write-Host ""
        Write-Host "PostgreSQL is available at:"
        Write-Host "  Host:     localhost"
        Write-Host "  Port:     $localPort"
        Write-Host "  Username: $dbUsername"
        Write-Host "  Password: $dbPassword"
        Write-Host "  Database: $dbName"
        Write-Host ""
        Write-Host "Connection string:"
        Write-Host "  $connectionString"
        Write-Host ""
        Write-Host "To connect:"
        Write-Host "  psql -h localhost -p $localPort -U $dbUsername -d $dbName"
        Write-Host "  # Enter password when prompted: $dbPassword"
        Write-Host ""
        Write-Host "To view logs:  .\proxy.ps1 logs"
        Write-Host "To stop:       .\proxy.ps1 stop"
    }
    else {
        Write-Host "Error: Failed to start proxy container" -ForegroundColor Red
        Write-Host "Check logs with: docker logs $ContainerName"
        exit 1
    }
}

# Function to stop proxy
function Stop-Proxy {
    Test-Docker

    Write-Host "Stopping proxy container..."

    docker stop $ContainerName 2>&1 | Out-Null
    docker rm $ContainerName 2>&1 | Out-Null

    Write-Host "✓ Proxy stopped for config: $ConfigFile" -ForegroundColor Green
}

# Function to restart proxy
function Restart-Proxy {
    Stop-Proxy
    Write-Host ""
    Start-Proxy
}

# Function to show status
function Show-Status {
    Test-Docker

    # Check if config file exists
    if (!(Test-Path $ConfigFile)) {
        Write-Host "Error: Configuration file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }

    $runningContainers = docker ps --format '{{.Names}}' 2>&1
    if ($runningContainers -contains $ContainerName) {
        Write-Host "✓ Proxy is running for config: $ConfigFile" -ForegroundColor Green
        Write-Host ""
        docker ps --filter "name=$ContainerName" --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}"

        Write-Host ""
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $connectionString = $config.database.connection_string
        Write-Host "Connection string:"
        Write-Host "  $connectionString"
    }
    else {
        Write-Host "✗ Proxy is not running for config: $ConfigFile" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To start the proxy, run: .\proxy.ps1 -Config $ConfigFile start"
    }
}

# Function to show logs
function Show-Logs {
    Test-Docker

    if ($RemainingArgs -contains "-f" -or $RemainingArgs -contains "--follow") {
        docker logs -f $ContainerName
    }
    else {
        docker logs $ContainerName
        Write-Host ""
        Write-Host "To follow logs, run: .\proxy.ps1 logs -f"
    }
}

# Function to test database connection
function Test-Connection {
    Test-Docker

    # Check if config file exists
    if (!(Test-Path $ConfigFile)) {
        Write-Host "Error: Configuration file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }

    # Check if proxy is running
    $runningContainers = docker ps --format '{{.Names}}' 2>&1
    if ($runningContainers -notcontains $ContainerName) {
        Write-Host "✗ Proxy is not running for config: $ConfigFile" -ForegroundColor Red
        Write-Host "Please start the proxy first: .\proxy.ps1 -Config $ConfigFile start"
        exit 1
    }

    # Read database credentials from config
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $dbUsername = $config.database.username
    $dbPassword = $config.database.password
    $dbName = $config.database.database
    $localPort = if ($config.local_port) { $config.local_port } else { 1337 }

    Write-Host "Testing connection to PostgreSQL via proxy..."
    Write-Host "Config: $ConfigFile"
    Write-Host "Container: $ContainerName"
    Write-Host ""

    # Test connection with psql
    $env:PGPASSWORD = $dbPassword

    # Run version check
    $versionResult = psql -h localhost -p $localPort -U $dbUsername -d $dbName -t -c "SELECT version();" 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        $version = ($versionResult | Select-Object -First 1).Trim()
        Write-Host $version
        Write-Host ""
        Write-Host "✅ Connection test successful!" -ForegroundColor Green

        # Get additional info
        Write-Host ""
        Write-Host "Database details:"
        $detailsQuery = @"
SELECT
    current_database() || '|' ||
    current_user || '|' ||
    inet_server_addr() || '|' ||
    inet_server_port() || '|' ||
    current_timestamp
"@
        $detailsResult = psql -h localhost -p $localPort -U $dbUsername -d $dbName -t -c $detailsQuery 2>&1

        if ($LASTEXITCODE -eq 0) {
            $details = ($detailsResult | Select-Object -First 1).Trim()
            $parts = $details -split '\|'
            if ($parts.Count -ge 5) {
                Write-Host "  Database: $($parts[0].Trim())"
                Write-Host "  User: $($parts[1].Trim())"
                Write-Host "  Server: $($parts[2].Trim()):$($parts[3].Trim())"
                Write-Host "  Timestamp: $($parts[4].Trim())"
            }
        }
    }
    else {
        Write-Host ""
        Write-Host "✗ Connection test failed!" -ForegroundColor Red
        Write-Host "Please check:"
        Write-Host "  1. Proxy is running (.\proxy.ps1 status)"
        Write-Host "  2. Database credentials are correct"
        Write-Host "  3. Check proxy logs (.\proxy.ps1 logs)"
        exit 1
    }

    Remove-Item Env:\PGPASSWORD
}

# Function to show help
function Show-Help {
    Write-Host "PostgreSQL RDS Proxy Manager" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\proxy.ps1 [-Config <file>] [command]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Config <file>  - Specify configuration file (default: proxy-config.json)"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  start    - Start the proxy container"
    Write-Host "  stop     - Stop the proxy container"
    Write-Host "  restart  - Restart the proxy container"
    Write-Host "  status   - Show proxy status"
    Write-Host "  test     - Test database connection"
    Write-Host "  logs     - Show container logs"
    Write-Host "  logs -f  - Follow container logs"
    Write-Host "  help     - Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\proxy.ps1 start                        # Start with default config"
    Write-Host "  .\proxy.ps1 -Config myconfig.json start  # Start with custom config"
    Write-Host "  .\proxy.ps1 status                       # Check if proxy is running"
    Write-Host "  .\proxy.ps1 test                         # Test database connection"
    Write-Host "  .\proxy.ps1 logs -f                      # Follow the logs"
    Write-Host "  .\proxy.ps1 stop                         # Stop the proxy"
}

# Main command handler
switch ($Command) {
    "start" {
        Start-Proxy
    }
    "stop" {
        Stop-Proxy
    }
    "restart" {
        Restart-Proxy
    }
    "status" {
        Show-Status
    }
    "logs" {
        Show-Logs
    }
    "test" {
        Test-Connection
    }
    { $_ -in "help", "--help", "-h" } {
        Show-Help
    }
    default {
        if ([string]::IsNullOrEmpty($Command)) {
            Show-Status
        }
        else {
            Write-Host "Unknown command: $Command" -ForegroundColor Red
            Write-Host ""
            Show-Help
            exit 1
        }
    }
}