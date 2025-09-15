#!/bin/bash

# Default config file
DEFAULT_CONFIG="proxy-config.json"
CONFIG_FILE="$DEFAULT_CONFIG"

# Parse command line arguments
COMMAND=""
REMAINING_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            if [ -z "$2" ]; then
                echo "Error: --config requires a file path"
                exit 1
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help|-h|help)
            COMMAND="help"
            shift
            ;;
        -*)
            # Unknown option
            echo "Unknown option: $1"
            echo "Use --config <file> to specify configuration file"
            exit 1
            ;;
        *)
            # This is the command (start, stop, etc.)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            else
                # Additional arguments for the command
                REMAINING_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

# Generate container name based on config file
# This allows multiple proxies with different configs
CONFIG_BASENAME=$(basename "$CONFIG_FILE" .json)
CONTAINER_NAME="postgres-ssm-proxy_${CONFIG_BASENAME}"

# Function to check if Docker is running
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        echo "Error: Docker is not running. Please start Docker first."
        exit 1
    fi
}

# Function to login to ECR and pull image
pull_image() {
    echo "Logging in to ECR..."

    # Get ECR URI from config
    ECR_URI=$(jq -r '.ecr.repository_uri' "$CONFIG_FILE")
    ECR_REGISTRY=$(echo $ECR_URI | cut -d'/' -f1)

    # Login to ECR
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
        aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin $ECR_REGISTRY

    if [ $? -ne 0 ]; then
        echo "Error: Failed to login to ECR"
        exit 1
    fi

    echo "Pulling Docker image from ECR..."
    docker pull $ECR_URI:latest

    if [ $? -eq 0 ]; then
        echo "✓ Docker image pulled successfully from ECR"
        # Tag the image for local use
        IMAGE_NAME=$ECR_URI:latest
    else
        echo "Error: Failed to pull Docker image from ECR"
        exit 1
    fi
}

# Function to start proxy
start_proxy() {
    check_docker

    # Check if config exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found: $CONFIG_FILE"
        echo "Please create a configuration file or specify one with --config"
        exit 1
    fi

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        echo "Installing jq..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew install jq 2>/dev/null
        else
            sudo apt-get install -y jq 2>/dev/null || sudo yum install -y jq 2>/dev/null
        fi
    fi

    # Read configuration
    INSTANCE_ID=$(jq -r '.bastion.instance_id' "$CONFIG_FILE")
    RDS_ENDPOINT=$(jq -r '.rds.endpoint' "$CONFIG_FILE")
    AWS_ACCESS_KEY_ID=$(jq -r '.aws_credentials.access_key_id' "$CONFIG_FILE")
    AWS_SECRET_ACCESS_KEY=$(jq -r '.aws_credentials.secret_access_key' "$CONFIG_FILE")
    AWS_REGION=$(jq -r '.aws_region // "eu-central-1"' "$CONFIG_FILE")
    LOCAL_PORT=$(jq -r '.local_port // 1337' "$CONFIG_FILE")
    DB_USERNAME=$(jq -r '.database.username' "$CONFIG_FILE")
    DB_PASSWORD=$(jq -r '.database.password' "$CONFIG_FILE")
    DB_NAME=$(jq -r '.database.database' "$CONFIG_FILE")
    CONNECTION_STRING=$(jq -r '.database.connection_string' "$CONFIG_FILE")
    ECR_URI=$(jq -r '.ecr.repository_uri' "$CONFIG_FILE")
    IMAGE_NAME="$ECR_URI:latest"

    # Export AWS credentials
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_REGION

    # Check if container is already running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Proxy is already running for config: $CONFIG_FILE"
        echo "To restart, run: ./proxy.sh --config $CONFIG_FILE restart"
        exit 0
    fi

    # Check bastion instance status
    echo "Checking bastion instance..."
    INSTANCE_STATE=$(AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
        aws ec2 describe-instances \
        --instance-ids $INSTANCE_ID \
        --region $AWS_REGION \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "not-found")

    if [ "$INSTANCE_STATE" == "stopped" ]; then
        echo "Starting bastion instance..."
        AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
            aws ec2 start-instances \
            --instance-ids $INSTANCE_ID \
            --region $AWS_REGION > /dev/null
        echo "Waiting for instance to be ready..."
        AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
            aws ec2 wait instance-status-ok \
            --instance-ids $INSTANCE_ID \
            --region $AWS_REGION
    elif [ "$INSTANCE_STATE" != "running" ]; then
        echo "Error: Bastion instance is in state: $INSTANCE_STATE"
        exit 1
    fi

    # Pull image from ECR
    pull_image

    # Remove any existing stopped container
    docker rm $CONTAINER_NAME 2>/dev/null || true

    # Start container
    echo "Starting proxy container..."

    docker run -d \
        --name $CONTAINER_NAME \
        --network host \
        -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
        -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
        -e AWS_REGION="$AWS_REGION" \
        -v "$(realpath "$CONFIG_FILE"):/config/proxy-config.json:ro" \
        --restart unless-stopped \
        $IMAGE_NAME

    # Wait for container to start
    sleep 2

    # Check if container is running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo ""
        echo "=== Proxy Started Successfully ==="
        echo "Container: $CONTAINER_NAME"
        echo "Config: $CONFIG_FILE"
        echo ""
        echo "PostgreSQL is available at:"
        echo "  Host:     localhost"
        echo "  Port:     $LOCAL_PORT"
        echo "  Username: $DB_USERNAME"
        echo "  Password: $DB_PASSWORD"
        echo "  Database: $DB_NAME"
        echo ""
        echo "Connection string:"
        echo "  $CONNECTION_STRING"
        echo ""
        echo "To connect:"
        echo "  psql -h localhost -p $LOCAL_PORT -U $DB_USERNAME -d $DB_NAME"
        echo "  # Enter password when prompted: $DB_PASSWORD"
        echo ""
        echo "To view logs:  ./proxy.sh logs"
        echo "To stop:       ./proxy.sh stop"
    else
        echo "Error: Failed to start proxy container"
        echo "Check logs with: docker logs $CONTAINER_NAME"
        exit 1
    fi
}

# Function to stop proxy
stop_proxy() {
    check_docker

    echo "Stopping proxy container..."

    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true

    echo "✓ Proxy stopped for config: $CONFIG_FILE"
}

# Function to restart proxy
restart_proxy() {
    stop_proxy
    echo ""
    start_proxy
}

# Function to show status
show_status() {
    check_docker

    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✓ Proxy is running for config: $CONFIG_FILE"
        echo ""
        docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

        echo ""
        CONNECTION_STRING=$(jq -r '.database.connection_string' "$CONFIG_FILE")
        echo "Connection string:"
        echo "  $CONNECTION_STRING"
    else
        echo "✗ Proxy is not running for config: $CONFIG_FILE"
        echo ""
        echo "To start the proxy, run: ./proxy.sh --config $CONFIG_FILE start"
    fi
}

# Function to show logs
show_logs() {
    check_docker

    if [ "$2" == "-f" ] || [ "$2" == "--follow" ]; then
        docker logs -f $CONTAINER_NAME
    else
        docker logs $CONTAINER_NAME
        echo ""
        echo "To follow logs, run: ./proxy.sh logs -f"
    fi
}

# Function to test database connection
test_connection() {
    check_docker

    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    # Check if proxy is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "✗ Proxy is not running for config: $CONFIG_FILE"
        echo "Please start the proxy first: ./proxy.sh --config $CONFIG_FILE start"
        exit 1
    fi

    # Read database credentials from config
    DB_USERNAME=$(jq -r '.database.username' "$CONFIG_FILE")
    DB_PASSWORD=$(jq -r '.database.password' "$CONFIG_FILE")
    DB_NAME=$(jq -r '.database.database' "$CONFIG_FILE")
    LOCAL_PORT=$(jq -r '.local_port // 1337' "$CONFIG_FILE")

    echo "Testing connection to PostgreSQL via proxy..."
    echo "Config: $CONFIG_FILE"
    echo "Container: $CONTAINER_NAME"
    echo ""

    # Test connection with psql
    export PGPASSWORD="$DB_PASSWORD"

    # Run version check
    psql -h localhost -p $LOCAL_PORT -U $DB_USERNAME -d $DB_NAME -t -c "SELECT version();" 2>&1 | head -1 | sed 's/^[[:space:]]*//'

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo ""
        echo "✅ Connection test successful!"

        # Get additional info
        echo ""
        echo "Database details:"
        RESULT=$(psql -h localhost -p $LOCAL_PORT -U $DB_USERNAME -d $DB_NAME -t -c "
            SELECT
                current_database() || '|' ||
                current_user || '|' ||
                inet_server_addr() || '|' ||
                inet_server_port() || '|' ||
                current_timestamp
        " 2>/dev/null | head -1)

        if [ -n "$RESULT" ]; then
            IFS='|' read -r db user addr port ts <<< "$RESULT"
            echo "  Database: $(echo $db | xargs)"
            echo "  User: $(echo $user | xargs)"
            echo "  Server: $(echo $addr | xargs):$(echo $port | xargs)"
            echo "  Timestamp: $(echo $ts | xargs)"
        fi
    else
        echo ""
        echo "✗ Connection test failed!"
        echo "Please check:"
        echo "  1. Proxy is running (./proxy.sh status)"
        echo "  2. Database credentials are correct"
        echo "  3. Check proxy logs (./proxy.sh logs)"
        exit 1
    fi

    unset PGPASSWORD
}


# Function to show help
show_help() {
    echo "PostgreSQL RDS Proxy Manager"
    echo ""
    echo "Usage: ./proxy.sh [--config <file>] [command]"
    echo ""
    echo "Options:"
    echo "  --config <file>  - Specify configuration file (default: proxy-config.json)"
    echo ""
    echo "Commands:"
    echo "  start    - Start the proxy container"
    echo "  stop     - Stop the proxy container"
    echo "  restart  - Restart the proxy container"
    echo "  status   - Show proxy status"
    echo "  test     - Test database connection"
    echo "  logs     - Show container logs"
    echo "  logs -f  - Follow container logs"
    echo "  help     - Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./proxy.sh start                        # Start with default config"
    echo "  ./proxy.sh --config myconfig.json start # Start with custom config"
    echo "  ./proxy.sh status                       # Check if proxy is running"
    echo "  ./proxy.sh test                         # Test database connection"
    echo "  ./proxy.sh logs -f                      # Follow the logs"
    echo "  ./proxy.sh stop                         # Stop the proxy"
}

# Main command handler
case "$COMMAND" in
    start)
        start_proxy
        ;;
    stop)
        stop_proxy
        ;;
    restart)
        restart_proxy
        ;;
    status)
        show_status
        ;;
    logs)
        # Pass remaining arguments for logs (like -f)
        show_logs logs "${REMAINING_ARGS[@]}"
        ;;
    test)
        test_connection
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        if [ -z "$COMMAND" ]; then
            show_status
        else
            echo "Unknown command: $COMMAND"
            echo ""
            show_help
            exit 1
        fi
        ;;
esac
