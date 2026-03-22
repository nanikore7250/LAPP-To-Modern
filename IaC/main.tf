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
    description = "Allow HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Leave egress unspecified so default allows outbound to instances

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
          amazon-linux-extras install postgresql14
          yum install -y httpd php php-pgsql nmap

          systemctl start httpd
          systemctl enable httpd

          # Give network a moment
          sleep 10

          # Create test table and insert sample rows into RDS
          export PGPASSWORD="${random_password.db_pw.result}"
          psql -h ${aws_db_instance.postgres.address} -U dbadmin -d appdb -c "CREATE TABLE IF NOT EXISTS test_data (id serial primary key, msg text);" || true
          psql -h ${aws_db_instance.postgres.address} -U dbadmin -d appdb -c "INSERT INTO test_data (msg) VALUES ('hello from EC2'), ('another row');" || true

          # PHP page that reads from RDS
          cat > /var/www/html/index.php <<'PHP'
          <?php
          $host = "${aws_db_instance.postgres.address}";
          $port = 5432;
          $db   = "appdb";
          $user = "dbadmin";
          $pass = "${random_password.db_pw.result}";

          try {
            $dsn = "pgsql:host=$host;port=$port;dbname=$db;";
            $pdo = new PDO($dsn, $user, $pass, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            $stmt = $pdo->query('SELECT id, msg FROM test_data ORDER BY id');
            echo "<h1>Test Data from RDS</h1>";
            echo "<ul>";
            while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
              echo "<li>" . htmlspecialchars($row['id']) . ": " . htmlspecialchars($row['msg']) . "</li>";
            }
            echo "</ul>";
          } catch (Exception $e) {
            echo "<p>Error connecting to DB: " . htmlspecialchars($e->getMessage()) . "</p>";
          }
          ?>
          PHP

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
    Name = "vulnerable-lamp"
    Env  = "lab"
    Risk = "high"
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

  ssl_policy     = "ELBSecurityPolicy-2016-08"
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

# Amazon Linux AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}