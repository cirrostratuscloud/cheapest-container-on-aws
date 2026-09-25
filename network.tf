data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# VPC with an Amazon-provided IPv6 /56 block.
# The VPC still carries an IPv4 CIDR (VPCs require one), but the task subnets
# below are IPv6-only, so tasks get no IPv4 address and egress over IPv6.
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block                       = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true

  tags = { Name = "${var.name}-vpc" }
}

# Egress-only internet gateway: outbound-only IPv6. Lets tasks reach the
# internet (public ECR, CloudWatch Logs over IPv6) with no inbound exposure
# and no NAT gateway cost.
resource "aws_egress_only_internet_gateway" "eigw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-eigw" }
}

# ---------------------------------------------------------------------------
# Private IPv6-only subnets for the Fargate tasks (one per AZ, two for spread).
# ipv6_native = true means no IPv4 CIDR is assigned to the subnet, so the task
# ENIs egress over IPv6 only (image pulls + logs) with no NAT.
# ---------------------------------------------------------------------------
resource "aws_subnet" "ipv6" {
  count = 2

  vpc_id = aws_vpc.main.id
  # Dual-stack: IPv6 for egress (image pull + logs) AND a private IPv4 so the
  # task registers AWS_INSTANCE_IPV4 in Cloud Map. API Gateway's Cloud Map
  # integration only resolves IPv4 targets, so the IPv4 is required for the
  # in-VPC VPC Link hop. It is NOT routed to the internet (no NAT), so egress
  # still goes over IPv6 only and there's no NAT gateway cost.
  cidr_block      = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  ipv6_cidr_block = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, count.index)

  availability_zone = data.aws_availability_zones.available.names[count.index]

  assign_ipv6_address_on_creation                = true
  enable_resource_name_dns_aaaa_record_on_launch = true

  tags = { Name = "${var.name}-task-${count.index}" }
}

resource "aws_route_table" "ipv6" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-rt-ipv6" }
}

# Default IPv6 route to the egress-only IGW (outbound only).
resource "aws_route" "ipv6_default" {
  route_table_id              = aws_route_table.ipv6.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.eigw.id
}

resource "aws_route_table_association" "ipv6" {
  count          = length(aws_subnet.ipv6)
  subnet_id      = aws_subnet.ipv6[count.index].id
  route_table_id = aws_route_table.ipv6.id
}

# ---------------------------------------------------------------------------
# Dual-stack subnets for the API Gateway VPC Link.
# The VPC Link's ENIs require IPv4 addresses (it rejects IPv6-only subnets with
# "Subnet should have at least '4' available IP Addresses"), so these carry a
# small IPv4 CIDR. They also get IPv6 so the link can reach the IPv6-only tasks.
# These subnets have no route to the internet, so no NAT is introduced.
# ---------------------------------------------------------------------------
resource "aws_subnet" "vpclink" {
  count = 2

  vpc_id = aws_vpc.main.id
  # /28 IPv4 (16 addresses) is plenty for the VPC Link ENIs.
  cidr_block      = cidrsubnet(aws_vpc.main.cidr_block, 12, count.index)
  ipv6_cidr_block = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, count.index + 100)

  availability_zone = data.aws_availability_zones.available.names[count.index]

  assign_ipv6_address_on_creation = true

  tags = { Name = "${var.name}-vpclink-${count.index}" }
}

# Dedicated route table with no internet route (link only needs in-VPC reach).
resource "aws_route_table" "vpclink" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-rt-vpclink" }
}

resource "aws_route_table_association" "vpclink" {
  count          = length(aws_subnet.vpclink)
  subnet_id      = aws_subnet.vpclink[count.index].id
  route_table_id = aws_route_table.vpclink.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

# Tasks: allow inbound from the VPC Link SG on the container port, allow all
# IPv6 egress (for public ECR pulls and CloudWatch Logs over IPv6).
resource "aws_security_group" "task" {
  name        = "${var.name}-task"
  description = "Fargate tasks"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-task" }
}

resource "aws_vpc_security_group_ingress_rule" "task_from_vpclink" {
  security_group_id            = aws_security_group.task.id
  referenced_security_group_id = aws_security_group.vpclink.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  description                  = "From API Gateway VPC Link"
}

resource "aws_vpc_security_group_egress_rule" "task_egress_ipv6" {
  security_group_id = aws_security_group.task.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
  description       = "All IPv6 egress (public ECR, CloudWatch Logs)"
}

# VPC Link: the ENIs API Gateway places in your subnets to reach the tasks.
resource "aws_security_group" "vpclink" {
  name        = "${var.name}-vpclink"
  description = "API Gateway VPC Link"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-vpclink" }
}

resource "aws_vpc_security_group_egress_rule" "vpclink_to_task" {
  security_group_id            = aws_security_group.vpclink.id
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  description                  = "To Fargate tasks"
}
