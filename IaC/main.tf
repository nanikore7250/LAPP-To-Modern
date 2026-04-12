provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/21"
  tags = {
    Name = "lab-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "public-subnet"
  }
}

# Second public subnet in another AZ for ALB
resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "public-subnet-2"
  }
}

# Private Subnet
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "private-subnet"
  }
}

# Second private subnet in a different AZ for RDS AZ coverage
resource "aws_subnet" "private2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "private-subnet-2"
  }
}

# Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
}

# Private route table (no IGW)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public2_assoc" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private2_assoc" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private_rt.id
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
}

# NAT Gateway in the public subnet to give private instances internet access
resource "aws_nat_gateway" "natgw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id
  tags = {
    Name = "nat-gateway"
  }
}

# Route for private route table to use NAT Gateway for internet access
resource "aws_route" "private_default_route" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.natgw.id
}


# ALB security group: allow HTTPS from internet
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-sg"
  }
}

# Security Group for EC2 web instances: allow HTTP only from the ALB
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-sg"
  }
}

# Allow HTTP (80) from ALB security group to web instances
resource "aws_security_group_rule" "web_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.web_sg.id
  source_security_group_id = aws_security_group.alb_sg.id
}

# EC2
resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  # Use SSM (Session Manager) for access: attach an instance profile below
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm_profile.name

  user_data = <<-EOF
          #!/bin/bash
          dnf install -y nginx python3 python3-pip postgresql15
          pip3 install fastapi uvicorn psycopg2-binary

          # Fetch DB password from SSM Parameter Store at boot time (not baked into image)
          DB_PASS=$(aws ssm get-parameter \
            --name "/lab/db/password" \
            --with-decryption \
            --query "Parameter.Value" \
            --output text \
            --region ${var.region})

          # Write password to a file outside the web root
          mkdir -p /etc/app
          printf '%s' "$DB_PASS" > /etc/app/db_password
          chmod 600 /etc/app/db_password

          # Give RDS a moment to become available
          sleep 10

          # Create test table and insert sample rows into RDS
          export PGPASSWORD="$DB_PASS"
          psql -h ${aws_db_instance.postgres.address} -U dbadmin -d appdb -c "CREATE TABLE IF NOT EXISTS test_data (id serial primary key, msg text);" || true
          psql -h ${aws_db_instance.postgres.address} -U dbadmin -d appdb -c "INSERT INTO test_data (msg) VALUES ('hello from FastAPI'), ('another row');" || true

          # FastAPI app
          mkdir -p /opt/app
          cat > /opt/app/main.py <<'PYTHON'
          import psycopg2
          from fastapi import FastAPI

          app = FastAPI()

          DB_HOST = "${aws_db_instance.postgres.address}"
          DB_NAME = "appdb"
          DB_USER = "dbadmin"
          DB_PASS = open("/etc/app/db_password").read().strip()

          @app.get("/")
          def get_data():
              conn = psycopg2.connect(host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS)
              cur = conn.cursor()
              cur.execute("SELECT id, msg FROM test_data ORDER BY id")
              rows = cur.fetchall()
              cur.close()
              conn.close()
              return {"data": [{"id": r[0], "msg": r[1]} for r in rows]}
          PYTHON

          # nginx as reverse proxy to uvicorn
          cat > /etc/nginx/conf.d/app.conf <<'NGINX'
          server {
              listen 80;
              location / {
                  proxy_pass http://127.0.0.1:8000;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
              }
          }
          NGINX

          # Disable default nginx server block to avoid port conflict
          sed -i 's/^\(\s*listen\s\+80\)/# \1/' /etc/nginx/nginx.conf

          # systemd service for uvicorn
          cat > /etc/systemd/system/app.service <<'SERVICE'
          [Unit]
          Description=FastAPI app via uvicorn
          After=network.target

          [Service]
          ExecStart=/usr/local/bin/uvicorn main:app --host 127.0.0.1 --port 8000
          WorkingDirectory=/opt/app
          Restart=always

          [Install]
          WantedBy=multi-user.target
          SERVICE

          systemctl daemon-reload
          systemctl enable app
          systemctl start app
          systemctl enable nginx
          systemctl start nginx

          systemctl stop sshd
          systemctl disable sshd
          systemctl stop postfix
          systemctl disable postfix
          systemctl stop rpcbind.socket
          systemctl disable rpcbind.socket
          systemctl stop rpcbind.service
          systemctl disable rpcbind.service

          EOF

  tags = {
    Name = "fastapi-app"
    Env  = "lab"
  }
}

# IAM role for SSM access
resource "aws_iam_role" "ec2_ssm_role" {
  name = "ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# RDS security group
resource "aws_security_group" "rds_sg" {
  name   = "rds-sg"
  vpc_id = aws_vpc.main.id

  description = "Allow Postgres access only from web instances"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Allow inbound Postgres (5432) from the web SG only
resource "aws_security_group_rule" "rds_from_web" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_sg.id
  source_security_group_id = aws_security_group.web_sg.id
}

# Application Load Balancer
resource "aws_lb" "alb" {
  name               = "app-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = [aws_subnet.public.id, aws_subnet.public2.id]
  security_groups    = [aws_security_group.alb_sg.id]
  tags = {
    Name = "app-alb"
  }
}

# Target group for ALB -> instances on port 80
resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Listener for HTTPS on ALB — expects you to wire a certificate ARN if you have one

# HTTP listener for ALB (useful for health checks / lab testing)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# Optional HTTPS listener: created only when a certificate ARN is provided
resource "aws_lb_listener" "https" {
  count             = var.alb_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.alb.arn
  port              = "443"
  protocol          = "HTTPS"

  ssl_policy     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# Attach instance to target group
resource "aws_lb_target_group_attachment" "web_attachment" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web.id
  port             = 80
}

# DB Subnet Group for RDS
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [aws_subnet.private.id, aws_subnet.private2.id]

  tags = {
    Name = "rds-subnet-group"
  }
}

# Random password for the DB
resource "random_password" "db_pw" {
  length = 16
  # Avoid special characters that RDS rejects (/, @, ", space)
  special = false
}

# Store DB password in SSM Parameter Store (SecureString)
resource "aws_ssm_parameter" "db_password" {
  name  = "/lab/db/password"
  type  = "SecureString"
  value = random_password.db_pw.result
}

# Allow EC2 to fetch the DB password from SSM
resource "aws_iam_role_policy" "ec2_get_db_param" {
  name = "ec2-get-db-param"
  role = aws_iam_role.ec2_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = aws_ssm_parameter.db_password.arn
    }]
  })
}

# RDS Postgres instance in private subnet
resource "aws_db_instance" "postgres" {
  identifier             = "lab-postgres"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  db_name                = "appdb"
  username               = "dbadmin"
  password               = random_password.db_pw.result
  parameter_group_name   = "default.postgres15"
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false
  storage_type           = "gp2"
  tags = {
    Name = "lab-postgres"
  }
}

# Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}