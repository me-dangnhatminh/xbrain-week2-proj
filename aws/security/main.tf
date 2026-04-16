resource "aws_security_group" "alb_sg" {
  name        = "xrestaurant-alb-sg"
  description = "Cho phep truy cap web (http/80) tu toan the internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP Public Access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}



resource "aws_security_group" "app_sg" {
  name        = "xrestaurant-app-sg"
  description = "Chi nhan traffic chuyen den tu Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Nhan traffic Web tu ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "data_sg" {
  name        = "xrestaurant-data-sg"
  description = "Chi nhan traffic tu tang App (MySQL & Redis)"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Giao tiep DocumentDB"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
