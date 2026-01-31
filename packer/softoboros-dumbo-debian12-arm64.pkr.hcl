packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  type    = string
  default = "ca-central-1"
}

variable "instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "ssh_username" {
  type    = string
  default = "admin"
}

variable "subnet_id" {
  type    = string
  default = ""
}

variable "security_group_id" {
  type    = string
  default = ""
}

locals {
  timestamp = regex_replace(timestamp(), ":|Z|T|\\+.*", "-")
}

source "amazon-ebs" "debian12_dumbo_arm64" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = var.ssh_username

  # Debian 12 (Bookworm) ARM64 AMI
  source_ami_filter {
    filters = {
      name                = "debian-12-arm64-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "arm64"
    }
    owners      = ["136693071363"] # Debian official
    most_recent = true
  }

  ami_name        = "softoboros-dumbo-debian12-arm64-${local.timestamp}"
  ami_description = "PostgreSQL 16 + pgvector + pgbouncer + Patroni HA on Debian 12 (arm64)"

  subnet_id                   = var.subnet_id == "" ? null : var.subnet_id
  security_group_id           = var.security_group_id == "" ? null : var.security_group_id
  associate_public_ip_address = var.subnet_id != "" ? true : null

  tags = {
    Name        = "softoboros-dumbo-debian12-arm64"
    Application = "softoboros"
    Component   = "dumbo"
    BaseOS      = "debian-12"
    Arch        = "arm64"
  }
}

build {
  name    = "softoboros-dumbo-debian12-arm64"
  sources = ["source.amazon-ebs.debian12_dumbo_arm64"]

  # Upload configuration files (dumbo-specific)
  provisioner "file" {
    source      = "packer/files-dumbo/"
    destination = "/tmp/pack_files"
  }

  # Upload common files (syslog forwarding, shared scripts)
  # Note: Copied from softoboros by buildspec before packer runs
  provisioner "file" {
    source      = "packer/files-common/"
    destination = "/tmp/pack_common"
  }

  # Upload redqueen system_table.py for infrastructure coordination
  # Note: Copied from softoboros by buildspec before packer runs
  provisioner "file" {
    source      = "packer/system_table.py"
    destination = "/tmp/system_table.py"
  }

  # Install prerequisites: AWS CLI v2, SSM Agent, utilities
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -uxo pipefail",
      "echo '[packer] Installing prerequisites'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq curl gnupg apt-transport-https lsb-release jq unzip gettext-base nvme-cli rsyslog dnsutils",

      "# Install AWS CLI v2 for arm64",
      "echo '[packer] Installing AWS CLI v2'",
      "curl -sL 'https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip' -o /tmp/awscliv2.zip",
      "cd /tmp && unzip -q awscliv2.zip && sudo ./aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip",

      "# Install AWS SSM Agent for arm64",
      "echo '[packer] Installing AWS SSM Agent'",
      "cd /tmp",
      "curl -sL 'https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_arm64/amazon-ssm-agent.deb' -o amazon-ssm-agent.deb",
      "sudo dpkg -i amazon-ssm-agent.deb",
      "sudo systemctl enable amazon-ssm-agent",
      "rm -f amazon-ssm-agent.deb",
      "echo '[packer] SSM Agent installed and enabled'"
    ]
  }

  # Install PostgreSQL 16, pgvector, and pgbouncer from PGDG repo
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -uxo pipefail",
      "echo '[packer] Adding PostgreSQL PGDG repository'",

      "# Add PGDG apt repository for PostgreSQL 16",
      "sudo install -d /usr/share/postgresql-common/pgdg",
      "sudo curl -sL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc",
      "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main' | sudo tee /etc/apt/sources.list.d/pgdg.list",

      "sudo apt-get update -qq",

      "echo '[packer] Installing PostgreSQL 16 + pgvector + pgbouncer'",
      "sudo apt-get install -y -qq postgresql-16 postgresql-16-pgvector pgbouncer",

      "# Show installed versions",
      "echo '[packer] Installed PostgreSQL version:'",
      "sudo -u postgres /usr/lib/postgresql/16/bin/postgres --version",
      "echo '[packer] Installed pgbouncer version:'",
      "pgbouncer --version || true",

      "echo '[packer] PostgreSQL installation complete'"
    ]
  }

  # Install Patroni for PostgreSQL HA
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -uxo pipefail",
      "echo '[packer] Installing Patroni for PostgreSQL HA'",

      "# Install Python pip and dependencies (git needed for pip install from GitHub)",
      "sudo apt-get install -y -qq git python3-pip python3-venv python3-psycopg2",

      "# Install Patroni with DynamoDB DCS in a virtual environment",
      "sudo python3 -m venv /opt/patroni",
      "sudo /opt/patroni/bin/pip install --upgrade pip",
      "sudo /opt/patroni/bin/pip install patroni boto3 psycopg2-binary",

      "# Install dynatroni DynamoDB DCS module from GitHub",
      "echo '[packer] Installing dynatroni DynamoDB DCS module'",
      "sudo /opt/patroni/bin/pip install git+https://github.com/SoftOboros/dynatroni.git",

      "# Install DynamoDB module into Patroni's DCS namespace (Patroni uses pkgutil discovery)",
      "PATRONI_DCS_PATH=$(/opt/patroni/bin/python -c 'import patroni.dcs; print(patroni.dcs.__path__[0])')",
      "echo \"Installing DynamoDB DCS module to $PATRONI_DCS_PATH\"",
      "sudo cp /opt/patroni/lib/python*/site-packages/dynatroni/dynamodb.py $PATRONI_DCS_PATH/dynamodb.py",
      "sudo chmod 644 $PATRONI_DCS_PATH/dynamodb.py",

      "# Create symlink for patroni binary",
      "sudo ln -sf /opt/patroni/bin/patroni /usr/local/bin/patroni",
      "sudo ln -sf /opt/patroni/bin/patronictl /usr/local/bin/patronictl",

      "# Create Patroni config directory",
      "sudo mkdir -p /etc/patroni",
      "sudo chown postgres:postgres /etc/patroni",

      "# Show installed version",
      "echo '[packer] Installed Patroni version:'",
      "/usr/local/bin/patroni --version",

      "echo '[packer] Patroni installation complete'"
    ]
  }

  # Install configuration files and systemd units
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -uxo pipefail",
      "echo '[packer] Installing configuration files'",

      "# Debug: show what was uploaded",
      "ls -laR /tmp/pack_files || true",

      "# Install PostgreSQL custom config",
      "sudo install -m 0644 -o postgres -g postgres $(find /tmp/pack_files -name '99-softoboros.conf' | head -1) /etc/postgresql/16/main/conf.d/99-softoboros.conf",

      "# Install managed pg_hba.conf (copied to data dir on every boot by patroni-configure)",
      "sudo install -m 0600 -o postgres -g postgres $(find /tmp/pack_files -name 'pg_hba.conf' | head -1) /etc/postgresql/16/main/pg_hba.conf",

      "# Install pgbouncer config template",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'pgbouncer.ini.template' | head -1) /etc/pgbouncer/pgbouncer.ini.template",

      "# Create pgbouncer directories",
      "sudo mkdir -p /var/run/pgbouncer /var/log/pgbouncer",
      "sudo chown postgres:postgres /var/run/pgbouncer /var/log/pgbouncer",
      "sudo chmod 0750 /var/run/pgbouncer /var/log/pgbouncer",

      "# Install scripts",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-attach.sh' | head -1) /usr/local/bin/dumbo-attach.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-fetch-secrets.sh' | head -1) /usr/local/bin/dumbo-fetch-secrets.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-init.sh' | head -1) /usr/local/bin/dumbo-init.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-pgbouncer-config.sh' | head -1) /usr/local/bin/dumbo-pgbouncer-config.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-watch.sh' | head -1) /usr/local/bin/dumbo-watch.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-configure-pg.sh' | head -1) /usr/local/bin/dumbo-configure-pg.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-register-dns.sh' | head -1) /usr/local/bin/dumbo-register-dns.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-register-refresh.sh' | head -1) /usr/local/bin/dumbo-register-refresh.sh",

      "# Install Patroni configuration template",
      "sudo install -m 0644 -o postgres -g postgres $(find /tmp/pack_files -name 'patroni.yml.template' | head -1) /etc/patroni/patroni.yml.template",

      "# Install Patroni scripts",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-patroni-configure.sh' | head -1) /usr/local/bin/dumbo-patroni-configure.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-patroni-callback.sh' | head -1) /usr/local/bin/dumbo-patroni-callback.sh",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_files -name 'dumbo-cold-boot-check.sh' | head -1) /usr/local/bin/dumbo-cold-boot-check.sh",

      "# Install common scripts and configs (syslog forwarding)",
      "sudo mkdir -p /var/spool/rsyslog",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_common -name 'softoboros-syslog-forward.sh' | head -1) /usr/local/bin/softoboros-syslog-forward.sh",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_common -name '00-softoboros-common.conf' | head -1) /etc/rsyslog.d/00-softoboros-common.conf",

      "# Install participant registration script",
      "sudo install -m 0755 -o root -g root $(find /tmp/pack_common -name 'softoboros-register-participant.sh' | head -1) /usr/local/bin/softoboros-register-participant.sh",

      "# Install redqueen module (for system table) - uses Patroni's Python",
      "sudo mkdir -p /usr/local/lib/softoboros/redqueen",
      "sudo cp /tmp/system_table.py /usr/local/lib/softoboros/redqueen/system_table.py",
      "echo '# redqueen module' | sudo tee /usr/local/lib/softoboros/redqueen/__init__.py",
      "sudo chmod 644 /usr/local/lib/softoboros/redqueen/*.py",

      "# Install systemd units",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-attach.service' | head -1) /etc/systemd/system/dumbo-attach.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-secrets.service' | head -1) /etc/systemd/system/dumbo-secrets.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-init.service' | head -1) /etc/systemd/system/dumbo-init.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-pgbouncer.service' | head -1) /etc/systemd/system/dumbo-pgbouncer.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-watch.service' | head -1) /etc/systemd/system/dumbo-watch.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-watch.timer' | head -1) /etc/systemd/system/dumbo-watch.timer",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-configure-pg.service' | head -1) /etc/systemd/system/dumbo-configure-pg.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-register-dns.service' | head -1) /etc/systemd/system/dumbo-register-dns.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'patroni.service' | head -1) /etc/systemd/system/patroni.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-syslog.service' | head -1) /etc/systemd/system/dumbo-syslog.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-register-refresh.service' | head -1) /etc/systemd/system/dumbo-register-refresh.service",
      "sudo install -m 0644 -o root -g root $(find /tmp/pack_files -name 'dumbo-register-refresh.timer' | head -1) /etc/systemd/system/dumbo-register-refresh.timer",

      "# Reload systemd and configure services",
      "sudo systemctl daemon-reload",

      "# Disable direct PostgreSQL management (Patroni controls PostgreSQL lifecycle)",
      "sudo systemctl disable postgresql@16-main || true",

      "# Enable Patroni (manages PostgreSQL HA)",
      "sudo systemctl enable patroni.service",

      "# Enable supporting services",
      "sudo systemctl enable dumbo-secrets.service",
      "sudo systemctl enable dumbo-configure-pg.service",
      "sudo systemctl enable dumbo-init.service",
      "sudo systemctl enable dumbo-pgbouncer.service",
      "sudo systemctl enable dumbo-register-dns.service",
      "sudo systemctl enable dumbo-watch.timer",
      "sudo systemctl enable dumbo-register-refresh.timer",

      "# Disable default pgbouncer autostart (we manage it via dumbo-pgbouncer.service)",
      "sudo systemctl disable pgbouncer.service || true",

      "# Enable EBS attach service (for ASG deployments with persistent storage)",
      "sudo systemctl enable dumbo-attach.service",

      "# Enable syslog forwarding service",
      "sudo systemctl enable dumbo-syslog.service",

      "# Disable apt auto-upgrades - production uses immutable AMIs, not live patching",
      "sudo systemctl disable --now apt-daily-upgrade.timer apt-daily.timer || true",
      "sudo systemctl mask apt-daily-upgrade.timer apt-daily.timer || true",

      "# Disable other nannyware - servers don't need man pages or ext4 scrubbing (EBS handles integrity)",
      "sudo systemctl disable --now man-db.timer e2scrub_all.timer || true",
      "sudo systemctl mask man-db.timer e2scrub_all.timer || true",

      "# Tune fstrim to run 4x daily instead of weekly (spread the load)",
      "sudo mkdir -p /etc/systemd/system/fstrim.timer.d",
      "echo -e '[Timer]\\nOnCalendar=\\nOnCalendar=*-*-* 00,06,12,18:00:00\\nRandomizedDelaySec=30m' | sudo tee /etc/systemd/system/fstrim.timer.d/override.conf",

      "echo '[packer] Configuration files installed'"
    ]
  }

  # Clean state before creating AMI
  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = [
      "set -uxo pipefail",
      "echo '[packer] Cleaning PostgreSQL state for fresh AMI'",

      "# Stop PostgreSQL",
      "sudo systemctl stop postgresql@16-main || true",

      "# Clear PGDATA (PostgreSQL will initialize fresh on first boot)",
      "sudo rm -rf /var/lib/postgresql/16/main/*",

      "# Clear logs",
      "sudo rm -rf /var/log/postgresql/*",
      "sudo rm -rf /var/log/pgbouncer/*",

      "# Clear apt cache",
      "sudo apt-get clean",

      "# Clear systemd journal",
      "sudo rm -rf /var/log/journal/* || true",
      "sudo rm -rf /run/log/journal/* || true",

      "# Reset cloud-init for fresh boot on new instances",
      "# Without this, userdata scripts won't run (stale semaphores from build)",
      "sudo cloud-init clean --logs",

      "# Clean up temp files",
      "rm -rf /tmp/pack_files /tmp/pack_common",

      "echo '[packer] AMI will boot with fresh PostgreSQL state'"
    ]
  }
}
