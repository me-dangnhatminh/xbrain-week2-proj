# =============================================================================
# MH2: AWS Network Firewall (Path A - Domain Allowlist)
# =============================================================================

resource "aws_networkfirewall_rule_group" "domain_allowlist" {
  capacity = 100
  name     = "${var.project_name}-domain-allowlist"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets = [
          ".amazonaws.com",
        ]
      }
    }
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = {
    Name = "${var.project_name}-domain-allowlist"
  }
}

resource "aws_networkfirewall_firewall_policy" "main" {
  name = "${var.project_name}-firewall-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_rule_group_reference {
      priority     = 1
      resource_arn = aws_networkfirewall_rule_group.domain_allowlist.arn
    }

    stateful_default_actions = ["aws:drop_established", "aws:alert_established"]
  }

  tags = {
    Name = "${var.project_name}-firewall-policy"
  }
}

resource "aws_networkfirewall_firewall" "main" {
  name                = "${var.project_name}-network-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn
  vpc_id              = aws_vpc.app.id

  subnet_mapping {
    subnet_id = aws_subnet.app_firewall.id
  }

  tags = {
    Name = "${var.project_name}-network-firewall"
  }
}

# =============================================================================
# Firewall Logging (Alert Logs → CloudWatch)
# =============================================================================

resource "aws_cloudwatch_log_group" "firewall_alert" {
  name              = "/aws/network-firewall/${var.project_name}-alerts"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-firewall-alerts"
  }
}

resource "aws_networkfirewall_logging_configuration" "main" {
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    log_destination_config {
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_alert.name
      }
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
    }
  }
}

# =============================================================================
# Route Table Update: Public RT return → Firewall Endpoint
# =============================================================================

locals {
  firewall_endpoint = [
    for s in aws_networkfirewall_firewall.main.firewall_status[0].sync_states :
    s.attachment[0].endpoint_id
    if s.availability_zone == "${var.aws_region}a"
  ][0]
}

# Return traffic: Public RT → Firewall for private subnet traffic
resource "aws_route" "public_return_to_firewall" {
  route_table_id         = aws_route_table.app_public.id
  destination_cidr_block = "10.0.11.0/24"
  vpc_endpoint_id        = local.firewall_endpoint
}
