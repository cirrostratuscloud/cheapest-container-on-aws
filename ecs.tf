# ---------------------------------------------------------------------------
# IAM: task execution role (pull image).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role (app identity). Empty for the demo but wired up for convenience.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# ---------------------------------------------------------------------------
# Account-level setting required for IPv6-only Fargate tasks. Without this,
# tasks in an IPv6-only subnet won't be assigned an IPv6 address.
# NOTE: this is a per-account/per-region default, not scoped to this stack.
# ---------------------------------------------------------------------------
resource "aws_ecs_account_setting_default" "dualstack_ipv6" {
  name  = "dualStackIPv6"
  value = "enabled"
}

# ---------------------------------------------------------------------------
# ECS cluster + Fargate task definition
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = var.name
}

# Enable both Fargate capacity providers on the cluster so the service can use
# FARGATE_SPOT (and fall back to FARGATE if desired).
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = var.name
      image     = var.image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      # Write the static cost-estimate page, then run nginx. Avoids building a
      # custom image for the demo.
      entryPoint = ["/bin/sh", "-c"]
      command    = ["printf '%s' \"$INDEX_HTML\" > /usr/share/nginx/html/index.html && exec nginx -g 'daemon off;'"]
      environment = [
        { name = "INDEX_HTML", value = file("${path.module}/site/index.html") }
      ]
      # No logConfiguration: the awslogs driver connects to CloudWatch over
      # IPv4 on a dual-stack task, and this subnet has no IPv4 egress (no NAT).
      # Dropping it lets the task start. For logs without a NAT, add a
      # CloudWatch Logs dual-stack interface VPC endpoint (~$7/mo).
    }
  ])
}

# ---------------------------------------------------------------------------
# Cloud Map: private DNS namespace + service. ECS registers task IPs here,
# and API Gateway's VPC Link integration targets this service directly.
# ---------------------------------------------------------------------------
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${var.name}.internal"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "app" {
  name = var.name

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    # SRV, not A/AAAA: API Gateway's Cloud Map integration calls
    # DiscoverInstances and needs both IP AND port in the returned attributes.
    # A/AAAA records register only the IP (no port), which yields a 500. SRV
    # records carry IP + port. ECS still registers the task's IPv6 address as
    # the SRV target since the task is IPv6-only.
    dns_records {
      type = "SRV"
      ttl  = 10
    }

    routing_policy = "MULTIVALUE"
  }
}

# ---------------------------------------------------------------------------
# ECS service. Registers into Cloud Map via service_registries.
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = var.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  # FARGATE_SPOT for the cheapest compute (up to ~70% off, 2-min interruption
  # warning). Falls back to on-demand FARGATE when use_spot = false.
  capacity_provider_strategy {
    capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  # Required when changing/adding a capacity provider strategy on a service.
  force_new_deployment = true

  network_configuration {
    subnets          = aws_subnet.ipv6[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.app.arn
    # SRV records require the container name + port so ECS can publish the port.
    container_name = var.name
    container_port = var.container_port
  }

  # Ensure IPv6-only assignment is enabled before the service launches tasks.
  depends_on = [aws_ecs_account_setting_default.dualstack_ipv6]
}
