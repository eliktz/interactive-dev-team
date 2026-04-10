# AWS Deployment Guide

This guide walks you through deploying Interactive Dev Team on an Amazon EC2
instance. By the end, you will have the war room and Paperclip running on a cloud
VM accessible from anywhere.

## Cost Estimate

| Resource | Spec | Monthly Cost (approx.) |
|----------|------|----------------------|
| EC2 instance | t3.medium (2 vCPU, 4 GB RAM) | ~$30 on-demand (~$19 Reserved) |
| EBS root volume | 20 GB gp3 | ~$2 |
| EBS data volume (optional) | 20 GB gp3 | ~$2 |
| Public IP | Auto-assigned (changes on stop/start) | $0 |
| Network egress | Minimal (mostly API calls) | ~$1-2 |
| **Total** | | **~$30-45/month** |

Note: This does not include Anthropic API costs, which vary based on usage. If you
use AWS Bedrock instead of the Anthropic API directly, Bedrock pricing applies (see
the [Using AWS Bedrock](#using-aws-bedrock-aws-native-llm-provider) section).

## Prerequisites

- An AWS account
- `aws` CLI v2 installed and configured (`aws configure`)
- A default region selected (e.g., `us-east-1`)

## Step 1: Create a Key Pair

Create an SSH key pair for connecting to the instance:

```bash
aws ec2 create-key-pair \
  --key-name interactive-dev-team \
  --key-type ed25519 \
  --query 'KeyMaterial' \
  --output text > interactive-dev-team.pem && chmod 400 interactive-dev-team.pem
```

Keep `interactive-dev-team.pem` safe -- you will need it to SSH into the instance.

## Step 2: Create a Security Group

Create a security group and open the required ports:

```bash
# Create the security group
SG_ID=$(aws ec2 create-security-group \
  --group-name interactive-dev-team-sg \
  --description "War room + Paperclip ports" \
  --query 'GroupId' \
  --output text)

echo "Security Group ID: $SG_ID"
```

Open SSH (port 22), ttyd (port 7681), and Paperclip (port 3100):

```bash
# SSH -- restrict to your current IP
MY_IP=$(curl -s https://checkip.amazonaws.com)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr ${MY_IP}/32

# ttyd web terminal
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 7681 \
  --cidr 0.0.0.0/0

# Paperclip UI
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 3100 \
  --cidr 0.0.0.0/0
```

> **Security note:** The `0.0.0.0/0` CIDR on ports 7681 and 3100 allows access from
> anywhere. For production use, restrict these to your IP address or VPN range. You
> should also set `TTYD_USERNAME` and `TTYD_PASSWORD` in `.env` to enable basic auth
> on the terminal.

## Step 3: Launch the EC2 Instance

First, find the latest Ubuntu 22.04 AMI for your region:

```bash
AMI_ID=$(aws ec2 describe-images \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text)

echo "AMI ID: $AMI_ID"
```

> **Note:** AMI IDs are region-specific. The command above finds the latest official
> Ubuntu 22.04 AMI for your configured region. If you switch regions, re-run it.

Launch the instance:

```bash
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.medium \
  --key-name interactive-dev-team \
  --security-group-ids $SG_ID \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=interactive-dev-team}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for the instance to be running
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
echo "Instance is running."
```

## Step 4: SSH into the Instance

Get the public DNS name and connect:

```bash
PUBLIC_DNS=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicDnsName' \
  --output text)

echo "Public DNS: $PUBLIC_DNS"

ssh -i interactive-dev-team.pem ubuntu@$PUBLIC_DNS
```

If the connection is refused, wait a minute for the instance to finish booting, then
try again.

## Step 5: Install Docker

Run the following on the instance:

```bash
# Install Docker using the official convenience script
curl -fsSL https://get.docker.com | sudo sh

# Add your user to the docker group (avoids needing sudo)
sudo usermod -aG docker $USER

# Apply group change (or log out and back in)
newgrp docker

# Verify Docker is working
docker --version
docker compose version
```

## Step 6: Clone the Repo and Configure

```bash
# Clone the project
git clone https://github.com/YOUR_ORG/interactive-dev-team.git
cd interactive-dev-team

# Create .env from the template
cp .env.example .env
```

Edit `.env` with your secrets. You can use `nano` or `vim`:

```bash
nano .env
```

Fill in at minimum:
- `ANTHROPIC_API_KEY` (or Bedrock credentials -- see [Using AWS Bedrock](#using-aws-bedrock-aws-native-llm-provider))
- `CAPTAIN_TELEGRAM_TOKEN`
- `CEO_GONORTH_TELEGRAM_TOKEN`
- `UX_GONORTH_TELEGRAM_TOKEN`
- `GONORTH_GROUP_ID`

For a cloud deployment, also set ttyd credentials:
- `TTYD_USERNAME=admin`
- `TTYD_PASSWORD=<a-strong-password>`

## Step 7: Run Setup

```bash
bash scripts/setup.sh
```

This will:
1. Check prerequisites (Docker, git)
2. Clone Paperclip into `./paperclip`
3. Build and start the Paperclip container
4. Wait for Paperclip to become healthy
5. Register the Go-North company and its agents
6. Write agent IDs to `.env.generated`

When prompted, choose whether to start the full stack now or do it manually.

## Step 8: Start the Full Stack

If you did not start during setup:

```bash
docker compose up -d
```

Verify everything is running:

```bash
docker compose ps
```

You should see both `war-room` and `paperclip` with status `Up` (and `healthy` for
paperclip).

## Step 9: Access Your War Room

Get your instance's public IP:

```bash
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

Or, if you are on the instance itself:

```bash
curl -s https://checkip.amazonaws.com
```

Then open in your browser:
- **War Room (ttyd):** `http://PUBLIC_IP:7681`
- **Paperclip UI:** `http://PUBLIC_IP:3100`

## Optional: HTTPS with Caddy Reverse Proxy

For production, you should serve both services over HTTPS. Caddy handles TLS
certificates automatically.

### Prerequisites

- A domain name pointing to your instance's IP (e.g., `warroom.example.com` and
  `paperclip.example.com`, or use subpaths on a single domain)

### Install Caddy

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo apt-get install caddy
```

### Configure Caddy

Create `/etc/caddy/Caddyfile`:

```
warroom.example.com {
    reverse_proxy localhost:7681
}

paperclip.example.com {
    reverse_proxy localhost:3100
}
```

Replace `warroom.example.com` and `paperclip.example.com` with your actual domains.

### Open HTTPS Ports and Restart

```bash
# Open port 80 (for ACME challenge)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# Open port 443 (HTTPS)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0

# Restart Caddy
sudo systemctl restart caddy
```

Caddy will automatically obtain and renew Let's Encrypt TLS certificates.

If using HTTPS, update `.env`:
```
PAPERCLIP_PUBLIC_URL=https://paperclip.example.com
```

## Optional: EBS Data Volume

By default, Docker volumes live on the root EBS volume. For data durability, attach
a separate EBS volume:

```bash
# Create an EBS volume in the same availability zone as your instance
AZ=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
  --output text)

VOLUME_ID=$(aws ec2 create-volume \
  --availability-zone $AZ \
  --size 20 \
  --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=war-room-data}]' \
  --query 'VolumeId' \
  --output text)

echo "Volume ID: $VOLUME_ID"

# Wait for the volume to be available
aws ec2 wait volume-available --volume-ids $VOLUME_ID

# Attach to instance
aws ec2 attach-volume \
  --volume-id $VOLUME_ID \
  --instance-id $INSTANCE_ID \
  --device /dev/xvdf
```

SSH into the instance and format/mount the volume:

```bash
ssh -i interactive-dev-team.pem ubuntu@$PUBLIC_DNS

# Wait a moment for the device to appear, then format and mount
sudo mkfs.ext4 /dev/xvdf
sudo mkdir -p /mnt/war-room-data
sudo mount /dev/xvdf /mnt/war-room-data

# Add to fstab for auto-mount on reboot
echo '/dev/xvdf /mnt/war-room-data ext4 defaults 0 2' | sudo tee -a /etc/fstab
```

Then update `docker-compose.yml` to use bind mounts instead of named volumes:

```yaml
volumes:
  # Replace named volumes with bind mounts to EBS data volume
  war-room-state:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/war-room-data/war-room-state
  paperclip-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/war-room-data/paperclip-data
```

Create the directories:

```bash
sudo mkdir -p /mnt/war-room-data/war-room-state
sudo mkdir -p /mnt/war-room-data/paperclip-data
sudo chown -R 1000:1000 /mnt/war-room-data  # UID 1000 = claude user in container
```

## Using AWS Bedrock (AWS-Native LLM Provider)

When running on EC2, you can use **AWS Bedrock** to invoke Claude models instead of
passing an Anthropic API key. The main advantage: with an IAM instance role, the EC2
instance automatically receives temporary credentials via the instance metadata
service, so you never need to store static API keys.

### Step 1: Enable Claude Models in Bedrock

Before using Bedrock, you must request access to the Claude models:

1. Open the [AWS Bedrock console](https://console.aws.amazon.com/bedrock/)
2. Navigate to **Model access** in the left sidebar
3. Click **Manage model access**
4. Select the Claude models you want (e.g., Claude Sonnet, Claude Haiku)
5. Submit the request -- access is typically granted within minutes

### Step 2: Create an IAM Role for EC2

Create an IAM role that allows the EC2 instance to call Bedrock:

```bash
# Create the trust policy (allows EC2 to assume the role)
cat > bedrock-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create the role
aws iam create-role \
  --role-name interactive-dev-team-bedrock \
  --assume-role-policy-document file://bedrock-trust-policy.json

# Create the permissions policy (allows invoking Bedrock models)
cat > bedrock-permissions-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:*::foundation-model/anthropic.*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name interactive-dev-team-bedrock \
  --policy-name BedrockInvokePolicy \
  --policy-document file://bedrock-permissions-policy.json
```

### Step 3: Attach the Role to the EC2 Instance

Create an instance profile, attach the role, and associate it with the instance:

```bash
# Create instance profile
aws iam create-instance-profile \
  --instance-profile-name interactive-dev-team-bedrock

# Add the role to the profile
aws iam add-role-to-instance-profile \
  --instance-profile-name interactive-dev-team-bedrock \
  --role-name interactive-dev-team-bedrock

# Wait a few seconds for IAM propagation
sleep 10

# Associate the instance profile with the EC2 instance
aws ec2 associate-iam-instance-profile \
  --instance-id $INSTANCE_ID \
  --iam-instance-profile Name=interactive-dev-team-bedrock
```

> **Tip:** If you are launching a new instance, you can pass
> `--iam-instance-profile Name=interactive-dev-team-bedrock` directly to
> `aws ec2 run-instances` instead.

### Step 4: Set the IMDSv2 Hop Limit

Docker containers access instance metadata through an extra network hop. By default,
IMDSv2 allows only 1 hop, which means containers cannot reach the metadata endpoint
to obtain credentials. Increase the hop limit to 2:

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id $INSTANCE_ID \
  --http-put-response-hop-limit 2 \
  --http-endpoint enabled
```

This is required for Docker containers to use the instance role credentials.

### Step 5: Configure .env for Bedrock

In your `.env` file, set the following:

```bash
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=us-east-1
```

**Do not** set `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY`. The EC2 instance will
automatically obtain temporary credentials from the instance metadata service via
the IAM role you attached. This is more secure than static keys because credentials
are rotated automatically and never written to disk.

If you previously set `ANTHROPIC_API_KEY`, you can remove it or leave it -- Bedrock
will be used when `CLAUDE_CODE_USE_BEDROCK=1` is set.

### Verifying Bedrock Access

SSH into the instance and test that the role is working:

```bash
# Should return the role name
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/

# Should return temporary credentials (AccessKeyId, SecretAccessKey, Token)
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/interactive-dev-team-bedrock
```

If these commands return errors, verify the instance profile association and the
IMDSv2 hop limit.

## Managing the Deployment

### View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f war-room
docker compose logs -f paperclip
```

### Restart

```bash
docker compose restart
```

### Update

```bash
cd ~/interactive-dev-team
git pull
docker compose up -d --build
```

### Stop

```bash
docker compose down
```

### Stop and Remove Data

```bash
docker compose down -v  # Warning: removes all volumes/state
```

## Cleanup

Terminate the instance and remove associated resources:

```bash
# Terminate the EC2 instance
aws ec2 terminate-instances --instance-ids $INSTANCE_ID

# Wait for termination to complete
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID

# Delete the security group (must wait for instance to terminate)
aws ec2 delete-security-group --group-id $SG_ID

# Delete the key pair
aws ec2 delete-key-pair --key-name interactive-dev-team

# Delete the local PEM file
rm -f interactive-dev-team.pem
```

If you created an EBS data volume:

```bash
aws ec2 delete-volume --volume-id $VOLUME_ID
```

If you created Bedrock IAM resources:

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name interactive-dev-team-bedrock \
  --role-name interactive-dev-team-bedrock

aws iam delete-instance-profile \
  --instance-profile-name interactive-dev-team-bedrock

aws iam delete-role-policy \
  --role-name interactive-dev-team-bedrock \
  --policy-name BedrockInvokePolicy

aws iam delete-role \
  --role-name interactive-dev-team-bedrock
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| ttyd shows blank page | war-room container not healthy | `docker compose logs war-room` -- check for API key errors |
| Telegram bots not responding | Token not set or invalid | Verify tokens in `.env`, check `docker compose logs war-room` for warnings |
| Paperclip UI not loading | Container not healthy yet | Wait 30-60s after startup; check `docker compose ps` for health status |
| "Paperclip did not become healthy" during setup | Build failure or port conflict | Check `docker compose logs paperclip`; ensure port 3100 is free |
| Cannot reach ports from browser | Security group rules missing | Verify with `aws ec2 describe-security-groups --group-ids $SG_ID` |
| SSH connection refused | Instance not ready or wrong key | Wait 1-2 minutes; verify key pair name matches; check `aws ec2 describe-instance-status --instance-ids $INSTANCE_ID` |
| Bedrock returns 403 | IAM role not attached or model not enabled | Check instance profile with `aws ec2 describe-iam-instance-profile-associations --filters Name=instance-id,Values=$INSTANCE_ID`; verify model access in Bedrock console |
| Docker cannot reach IMDS for Bedrock credentials | IMDSv2 hop limit is 1 (default) | Run `aws ec2 modify-instance-metadata-options --instance-id $INSTANCE_ID --http-put-response-hop-limit 2 --http-endpoint enabled` |
| EBS volume not visible after attach | Device name differs | Run `lsblk` to find the correct device name (may be `/dev/xvdf`, `/dev/nvme1n1`, etc.) |
