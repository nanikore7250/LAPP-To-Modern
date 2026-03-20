provider "aws" {
  region = var.region
}

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

  tags = {
    Name = "public-subnet"
  }
}

# Route Table
resource "aws_route_table" "public_rt" {
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

# Security Group（自分IPのみ）
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    description = "SSH open"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP open"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Postgres open (vulnerable)"
    from_port   = 5432
    to_port     = 5432
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
    Name = "web-sg"
  }
}

# EC2
resource "aws_instance" "web" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  key_name      = var.key_name

  user_data = <<-EOF
              #!/bin/bash
              # Intentionally vulnerable setup (no system update)
              yum install -y httpd php postgresql-server nmap

              systemctl start httpd
              systemctl enable httpd

              postgresql-setup initdb
              systemctl start postgresql
              systemctl enable postgresql

              # Allow remote connections (vulnerable: listen on all interfaces)
              sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/data/postgresql.conf || true
              echo "host all all 0.0.0.0/0 md5" >> /var/lib/pgsql/data/pg_hba.conf || true

              # Create weak DB user and database
              sudo -u postgres psql -c "CREATE USER vulnuser WITH PASSWORD 'password';" || true
              sudo -u postgres psql -c "CREATE DATABASE vuln_db OWNER vulnuser;" || true

              # Simple PHP app (for demonstration)
              cat > /var/www/html/index.php <<'PHP'
              <?php
                phpinfo();
              ?>
              PHP
              EOF

  tags = {
    Name = "vulnerable-lamp"
    Env  = "lab"
    Risk = "high"
  }
}

# Amazon Linux AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}