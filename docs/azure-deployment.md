# Azure Deployment Guide

This guide walks you through deploying Interactive Dev Team on an Azure Virtual
Machine. By the end, you will have the war room and Paperclip running on a cloud
VM accessible from anywhere.

## Cost Estimate

| Resource | Spec | Monthly Cost (approx.) |
|----------|------|----------------------|
| Azure VM | Standard_B2s (2 vCPU, 4 GB RAM) | ~$30 |
| OS disk | 30 GB Premium SSD | ~$5 |
| Managed data disk (optional) | 20 GB Premium SSD | ~$5 |
| Static public IP | 1 Standard SKU IP | ~$3-4 |
| Network egress | Minimal (mostly API calls) | ~$1-2 |
| **Total** | | **~$35-45/month** |

Note: This does not include Anthropic API costs, which vary based on usage.

## Prerequisites

- An Azure account with an active subscription
- `az` CLI installed and authenticated (`az login`)
- A subscription selected (`az account set --subscription YOUR_SUBSCRIPTION`)

## Step 1: Create a Resource Group

```bash
az group create --name interactive-dev-team-rg --location eastus
```

## Step 2: Create the VM

```bash
az vm create \
  --resource-group interactive-dev-team-rg \
  --name interactive-dev-team \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --os-disk-size-gb 30 \
  --storage-sku Premium_LRS \
  --public-ip-sku Standard
```

## Step 3: Open Firewall Ports

Allow traffic to ttyd (7681) and Paperclip (3100):

```bash
az vm open-port \
  --resource-group interactive-dev-team-rg \
  --name interactive-dev-team \
  --port 7681 \
  --priority 1001

az vm open-port \
  --resource-group interactive-dev-team-rg \
  --name interactive-dev-team \
  --port 3100 \
  --priority 1002
```

> **Security note:** The default NSG rules created by `az vm open-port` allow
> access from anywhere (`*`). For production use, restrict the source IP by adding
> `--source-address-prefixes YOUR_IP/32` to each command. You should also set
> `TTYD_USERNAME` and `TTYD_PASSWORD` in `.env` to enable basic auth on the terminal.

## Step 4: SSH into the VM

```bash
ssh azureuser@$(az vm show -g interactive-dev-team-rg -n interactive-dev-team --show-details --query publicIps -o tsv)
```

## Step 5: Install Docker

Run the following on the VM:

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
- `ANTHROPIC_API_KEY` (or Bedrock credentials)
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

Get your VM's external IP:

```bash
az vm show -g interactive-dev-team-rg -n interactive-dev-team --show-details --query publicIps -o tsv
```

Then open in your browser:
- **War Room (ttyd):** `http://EXTERNAL_IP:7681`
- **Paperclip UI:** `http://EXTERNAL_IP:3100`

## Optional: HTTPS with Caddy Reverse Proxy

For production, you should serve both services over HTTPS. Caddy handles TLS
certificates automatically.

### Prerequisites

- A domain name pointing to your VM's IP (e.g., `warroom.example.com` and
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
az vm open-port \
  --resource-group interactive-dev-team-rg \
  --name interactive-dev-team \
  --port 80 \
  --priority 1003

# Open port 443 (HTTPS)
az vm open-port \
  --resource-group interactive-dev-team-rg \
  --name interactive-dev-team \
  --port 443 \
  --priority 1004

# Restart Caddy
sudo systemctl restart caddy
```

Caddy will automatically obtain and renew Let's Encrypt TLS certificates.

If using HTTPS, update `.env`:
```
PAPERCLIP_PUBLIC_URL=https://paperclip.example.com
```

## Optional: Managed Data Disk

By default, Docker volumes live on the OS disk. For data durability, attach a
separate managed disk:

```bash
# Create a managed disk
az disk create \
  --resource-group interactive-dev-team-rg \
  --name war-room-data \
  --size-gb 20 \
  --sku Premium_LRS

# Attach to VM
az vm disk attach \
  --resource-group interactive-dev-team-rg \
  --vm-name interactive-dev-team \
  --name war-room-data

# SSH in and format/mount
ssh azureuser@$(az vm show -g interactive-dev-team-rg -n interactive-dev-team --show-details --query publicIps -o tsv)

sudo mkfs.ext4 /dev/sdc
sudo mkdir -p /mnt/war-room-data
sudo mount /dev/sdc /mnt/war-room-data

# Add to fstab for auto-mount on reboot
echo '/dev/sdc /mnt/war-room-data ext4 defaults 0 2' | sudo tee -a /etc/fstab
```

Then update `docker-compose.yml` to use bind mounts instead of named volumes:

```yaml
volumes:
  # Replace named volumes with bind mounts to managed disk
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

Delete the entire resource group to remove all resources at once:

```bash
az group delete --name interactive-dev-team-rg --yes --no-wait
```

This removes the VM, disks, network security group, public IP, virtual network,
and all other resources created within the resource group.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| ttyd shows blank page | war-room container not healthy | `docker compose logs war-room` -- check for API key errors |
| Telegram bots not responding | Token not set or invalid | Verify tokens in `.env`, check `docker compose logs war-room` for warnings |
| Paperclip UI not loading | Container not healthy yet | Wait 30-60s after startup; check `docker compose ps` for health status |
| "Paperclip did not become healthy" during setup | Build failure or port conflict | Check `docker compose logs paperclip`; ensure port 3100 is free |
| Cannot reach ports from browser | NSG rules not applied | Verify with `az network nsg rule list -g interactive-dev-team-rg --nsg-name interactive-dev-teamNSG -o table` |
| SSH connection refused | VM not running or IP changed | Check VM status with `az vm show -g interactive-dev-team-rg -n interactive-dev-team --show-details -o table` |
| Disk not visible after attach | Device path differs | Run `lsblk` to find the correct device name (may be `/dev/sdc` or `/dev/sdd`) |
