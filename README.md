# RDS Proxy

A secure PostgreSQL database proxy tool that enables connections to AWS RDS instances through EC2 bastion hosts using AWS Systems Manager (SSM) sessions.

## Features

- 🔒 **Secure Tunneling** - Connect to private RDS instances via SSM sessions without SSH keys
- 🐳 **Docker-based** - Containerized proxy for consistent execution across environments
- 🔄 **Auto-management** - Automatically starts stopped bastion instances
- 🖥️ **Cross-platform** - Native support for Linux, macOS, and Windows
- 📊 **Connection Testing** - Built-in database connectivity validation
- 📝 **Log Management** - Real-time log viewing and monitoring

## Prerequisites

### Required Software
- **Docker** - Container runtime for proxy execution
- **AWS CLI** - For AWS service interactions
- **jq** - JSON parsing (auto-installed on Unix systems)
- **psql** (optional) - PostgreSQL client for connection testing

### AWS Requirements
- AWS account with appropriate IAM permissions
- EC2 bastion instance with SSM agent installed
- RDS PostgreSQL instance
- Properly configured security groups and VPC

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd prx
```

2. Create your configuration file:
```bash
cp proxy-config.example.json proxy-config.json
```

3. Edit `proxy-config.json` with your AWS and database details

4. Make the script executable:
```bash
# For Linux/macOS
chmod +x proxy.sh

# For Windows, use PowerShell
```

## Configuration

Create a `proxy-config.json` file with the following structure:

```json
{
  "aws": {
    "accessKeyId": "YOUR_ACCESS_KEY",
    "secretAccessKey": "YOUR_SECRET_KEY",
    "region": "eu-central-1",
    "vpcId": "vpc-xxxxx"
  },
  "ecr": {
    "repositoryName": "proxy-repo",
    "repositoryUri": "xxxx.dkr.ecr.region.amazonaws.com/proxy-repo",
    "registryId": "xxxx"
  },
  "bastion": {
    "instanceId": "i-xxxxx",
    "name": "bastion-instance",
    "type": "t3.micro",
    "securityGroups": ["sg-xxxxx"],
    "iamRole": "bastion-role",
    "instanceProfile": "bastion-profile"
  },
  "rds": {
    "instanceId": "rds-instance",
    "endpoint": "instance.xxxxx.region.rds.amazonaws.com",
    "port": 5432,
    "securityGroup": "sg-xxxxx"
  },
  "database": {
    "username": "postgres",
    "password": "YOUR_PASSWORD",
    "database": "postgres",
    "localPort": 1337
  }
}
```

## Usage

### Basic Commands

#### Start the proxy
```bash
# Linux/macOS
./proxy.sh start

# Windows PowerShell
.\proxy.ps1 start

# With custom config file
./proxy.sh --config custom-config.json start
```

#### Stop the proxy
```bash
./proxy.sh stop
```

#### Restart the proxy
```bash
./proxy.sh restart
```

#### Check status
```bash
./proxy.sh status
```

#### Test database connection
```bash
./proxy.sh test
```

#### View logs
```bash
# View last 50 lines
./proxy.sh logs

# Follow logs in real-time
./proxy.sh logs -f
```

#### Get help
```bash
./proxy.sh help
```

### Connecting to the Database

Once the proxy is running, connect to your PostgreSQL database using:

```bash
# Using psql
psql -h localhost -p 1337 -U postgres -d postgres

# Using connection string
psql "postgresql://postgres:password@localhost:1337/postgres"
```

Or configure your application to connect to:
- **Host**: `localhost`
- **Port**: `1337` (or your configured port)
- **Database**: Your database name
- **Username**: Your database username
- **Password**: Your database password

## Architecture

```
┌──────────────┐       ┌──────────────┐       ┌──────────────┐
│   Client     │──────▶│  RDS Proxy   │──────▶│   Bastion    │
│ Application  │ :1337 │  (Docker)    │  SSM  │   (EC2)      │
└──────────────┘       └──────────────┘       └──────────────┘
                                                      │
                                                      ▼
                                              ┌──────────────┐
                                              │     RDS      │
                                              │  PostgreSQL  │
                                              └──────────────┘
```

### How It Works

1. **Initialization**: Script reads configuration from `proxy-config.json`
2. **Bastion Check**: Verifies bastion instance status, starts if stopped
3. **ECR Authentication**: Logs into AWS ECR to pull proxy container
4. **Container Launch**: Starts Docker container with proxy application
5. **SSM Tunnel**: Establishes secure tunnel through bastion to RDS
6. **Local Proxy**: Exposes database on localhost port for client connections

## Security

### Best Practices

⚠️ **Important Security Considerations**:

1. **Never commit** `proxy-config.json` to version control (already in `.gitignore`)
2. **Use IAM roles** instead of hardcoded AWS credentials when possible
3. **Rotate credentials** regularly
4. **Restrict security groups** to minimum required access
5. **Enable RDS encryption** at rest and in transit
6. **Use AWS Secrets Manager** for production deployments

### Recommended Setup

For production environments:
- Use AWS IAM instance profiles for EC2 bastion
- Store database credentials in AWS Secrets Manager
- Enable VPC flow logs for audit trails
- Implement CloudTrail for API call logging
- Use Parameter Store for configuration management

## Troubleshooting

### Common Issues

#### Proxy won't start
- Check Docker is running: `docker info`
- Verify AWS credentials: `aws sts get-caller-identity`
- Ensure bastion instance is running: `./proxy.sh status`

#### Connection refused
- Verify security groups allow traffic between bastion and RDS
- Check RDS instance is available
- Ensure local port is not already in use

#### Authentication failed
- Verify database credentials in configuration
- Check RDS master password hasn't been changed
- Ensure database user has appropriate permissions

#### SSM session fails
- Verify bastion has SSM agent installed and running
- Check IAM role has necessary SSM permissions
- Ensure bastion can reach SSM endpoints

### Debug Mode

For detailed debugging output:
```bash
# Linux/macOS
DEBUG=1 ./proxy.sh start

# View container logs
docker logs rds-proxy -f
```

## Development

### Project Structure
```
prx/
├── proxy.sh           # Linux/macOS management script
├── proxy.ps1          # Windows PowerShell script
├── proxy-config.json  # Configuration file (gitignored)
├── README.md          # This file
└── .gitignore         # Git ignore rules
```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

### Testing

Run the built-in test suite:
```bash
# Test connection
./proxy.sh test

# Verify container status
docker ps | grep rds-proxy

# Check SSM session
aws ssm describe-sessions --state Active
```

## License

[Specify your license here]

## Support

For issues, questions, or contributions, please [open an issue](link-to-issues) on GitHub.

## Acknowledgments

- AWS Systems Manager for secure tunneling
- Docker for containerization
- PostgreSQL community

---

**Note**: This tool is designed for development and testing environments. For production use, consider AWS RDS Proxy service or implement additional security measures.