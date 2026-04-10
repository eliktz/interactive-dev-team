# GCP Deployment Guide

This guide walks you through deploying Interactive Dev Team on a Google Cloud Compute
Engine (GCE) virtual machine. By the end, you will have the war room and Paperclip
running on a cloud VM accessible from anywhere.

## Cost Estimate

| Resource | Spec | Monthly Cost (approx.) |
|----------|------|----------------------|
| GCE VM | e2-medium (2 vCPU, 4 GB RAM) | ~$25-30 |
| Boot disk | 20 GB SSD | ~$3 |
| Persistent disk (optional) | 20 GB SSD | ~$3 |
| Static IP | 1 external IP | ~$3-5 |
| Network egress | Minimal (mostly API calls) | ~$1-2 |
| **Total** | | **~$35-45/month** |

Note: This does not include Anthropic API costs, which vary based on usage.

## Prerequisites

- A Google Cloud account with billing enabled
- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- A project selected (`gcloud config set project YOUR_PROJECT`)

## Step 1: Create the VM

```bash
gcloud compute instances create interactive-dev-team \
  --zone=us-central1-a \
  --machine-type=e2-medium \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-ssd \
  --tags=war-room
```

## Step 2: Open Firewall Ports

Allow traffic to ttyd (7681) and Paperclip (3100):

```bash
gcloud compute firewall-rules create allow-war-room \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:7681,tcp:3100 \
  --target-tags=war-room \
  --source-ranges=0.0.0.0/0 \
  --description="Allow ttyd and Paperclip web UI"
```

> **Security note:** The `0.0.0.0/0` source range allows access from anywhere. For
> production use, restrict this to your IP address or VPN range. You should also set
> `TTYD_USERNAME` and `TTYD_PASSWORD` in `.env` to enable basic auth on the terminal.

## Step 3: SSH into the VM

```bash
gcloud compute ssh interactive-dev-team --zone=us-central1-a
```

## Step 4: Install Docker

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

## Step 5: Clone the Repo and Configure

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

## Step 6: Run Setup

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

## Step 7: Start the Full Stack

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

## Step 8: Access Your War Room

Get your VM's external IP:

```bash
gcloud compute instances describe interactive-dev-team \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
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

### Open HTTPS Port and Restart

```bash
# Open port 443 (HTTPS) and 80 (for ACME challenge)
gcloud compute firewall-rules create allow-https \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80,tcp:443 \
  --target-tags=war-room \
  --source-ranges=0.0.0.0/0

# Restart Caddy
sudo systemctl restart caddy
```

Caddy will automatically obtain and renew Let's Encrypt TLS certificates.

If using HTTPS, update `.env`:
```
PAPERCLIP_PUBLIC_URL=https://paperclip.example.com
```

## Optional: Persistent Disk

By default, Docker volumes live on the boot disk. For data durability, attach a
separate persistent disk:

```bash
# Create a persistent disk
gcloud compute disks create war-room-data \
  --zone=us-central1-a \
  --size=20GB \
  --type=pd-ssd

# Attach to VM
gcloud compute instances attach-disk interactive-dev-team \
  --zone=us-central1-a \
  --disk=war-room-data

# SSH in and format/mount
gcloud compute ssh interactive-dev-team --zone=us-central1-a

sudo mkfs.ext4 /dev/sdb
sudo mkdir -p /mnt/war-room-data
sudo mount /dev/sdb /mnt/war-room-data

# Add to fstab for auto-mount on reboot
echo '/dev/sdb /mnt/war-room-data ext4 defaults 0 2' | sudo tee -a /etc/fstab
```

Then update `docker-compose.yml` to use bind mounts instead of named volumes:

```yaml
volumes:
  # Replace named volumes with bind mounts to persistent disk
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

> **Note:** `docker compose restart` reuses the existing image. If you have pulled
> new code, use `docker compose up -d --build` instead to rebuild with the latest
> Dockerfile and launch.sh changes.

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

To remove all resources created by this guide:

```bash
# Delete the VM
gcloud compute instances delete interactive-dev-team --zone=us-central1-a --quiet

# Delete the firewall rule
gcloud compute firewall-rules delete allow-war-room --quiet

# Delete persistent disk (if created)
gcloud compute disks delete war-room-data --zone=us-central1-a --quiet

# Delete HTTPS firewall rule (if created)
gcloud compute firewall-rules delete allow-https --quiet
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| ttyd shows blank page | war-room container not healthy | `docker compose logs war-room` -- check for API key errors |
| Telegram bots not responding | Token not set or invalid | Verify tokens in `.env`, check `docker compose logs war-room` for warnings |
| Paperclip UI not loading | Container not healthy yet | Wait 30-60s after startup; check `docker compose ps` for health status |
| "Paperclip did not become healthy" during setup | Build failure or port conflict | Check `docker compose logs paperclip`; ensure port 3100 is free |
| Cannot reach ports from browser | Firewall rules not applied | Verify `gcloud compute firewall-rules list` includes your rules |
