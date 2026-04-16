resource "aws_docdb_subnet_group" "docdb_subnet_group" {
  name       = "xrestaurant-docdb-subnet-group"
  subnet_ids = var.database_subnets

  tags = {
    Name = "5XRestaurant DocDB Subnet Group"
  }
}

resource "aws_docdb_cluster" "mongodb" {
  cluster_identifier      = "xrestaurant-docdb-cluster"
  engine                  = "docdb"
  master_username         = var.db_username
  master_password         = var.db_password
  db_subnet_group_name    = aws_docdb_subnet_group.docdb_subnet_group.name
  vpc_security_group_ids  = [var.data_sg_id]
  skip_final_snapshot     = true
  
  # Bảo mật TLS (bắt buộc theo mặc định, nhưng ta cứ ghi rõ nếu cần)
  # Tuy nhiên provider docdb không có param tls_enabled trực tiếp ở đây,
  # mà được quản lí trong cluster parameter group. Ở đây ta dùng mặc định của AWS thì TLS luôn bật.
}

resource "aws_docdb_cluster_instance" "mongodb_instance" {
  count              = 1
  identifier         = "xrestaurant-docdb-instance-${count.index}"
  cluster_identifier = aws_docdb_cluster.mongodb.id
  instance_class     = "db.t3.medium"
}
