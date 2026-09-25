variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "cheapo"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 80
}

variable "image" {
  description = <<-EOT
    Container image to run. Must use the DUAL-STACK public ECR endpoint
    (ecr-public.aws.com) so an IPv6-only task can pull it. The classic
    public.ecr.aws endpoint is IPv4-only and fails with "network unreachable".
  EOT
  type        = string
  default     = "ecr-public.aws.com/nginx/nginx:stable"
}

variable "task_cpu" {
  description = "Fargate task CPU units (1024 = 1 vCPU)."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of tasks to run."
  type        = number
  default     = 1
}

variable "cpu_architecture" {
  description = "Task CPU architecture. ARM64 (Graviton) is ~20% cheaper than X86_64."
  type        = string
  default     = "ARM64"
}

variable "use_spot" {
  description = "Run on Fargate Spot (up to ~70% cheaper, can be interrupted with a 2-min warning). ARM64 Spot is supported."
  type        = bool
  default     = true
}
