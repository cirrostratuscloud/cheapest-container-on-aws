# cheapest-container-on-aws

How cheap can an always-on, publicly-reachable container be on AWS? This is the
answer: an App Runner-ish stack with usage-based billing and no always-on
infrastructure tax. Runs a public nginx image, so there's nothing to build.

```
API Gateway HTTP API  (per-request)
  └─ VPC Link  (no NLB, no hourly fee on HTTP APIs)
       └─ Cloud Map service  (ECS service discovery, SRV records)
            └─ Fargate task, ARM64 + Spot, in a private DUAL-STACK subnet
                 ├─ egress over IPv6 only (egress-only IGW) — image pull, etc.
                 └─ private IPv4, used ONLY for the in-VPC VPC Link hop
```

**No NAT gateway. No load balancer. No PrivateLink interface endpoints.** The only
recurring costs are Fargate vCPU/memory-seconds and per-request API Gateway charges.

The task runs on **ARM64 (Graviton) + Fargate Spot** for the cheapest possible
always-on container. At the minimum size (0.25 vCPU / 0.5 GB) that's **~$2.71/mo**
regardless of traffic. See [COST.md](./COST.md) — the running site serves the same
breakdown at `/` (custom page injected via the container command; see `site/index.html`).
Toggle with the `cpu_architecture` and `use_spot` variables.

## The core trick: dual-stack subnet, IPv6-only egress

The goal is App Runner economics: pay for CPU/memory and per-request, with no
always-on NAT gateway (~$32/mo) or load balancer (~$16/mo). Getting there took
working around two hard AWS limits, both discovered the hard way:

1. **API Gateway's Cloud Map integration only resolves IPv4 targets.** An
   IPv6-only task registers only `AWS_INSTANCE_IPV6`, so `DiscoverInstances`
   returns "No target endpoints found" and every request 500s. The task therefore
   needs a private **IPv4** address for the VPC Link hop.
2. **A NAT gateway is the expensive part, not the IPv4 address itself.** So the
   task subnet is dual-stack, but its route table has **no IPv4 default route** —
   only an IPv6 default route to an egress-only internet gateway. The private IPv4
   is used purely for in-VPC traffic (the VPC Link reaching the task); all internet
   egress (pulling the image) goes over IPv6. No NAT, no cost.

So: dual-stack subnet, IPv4 stays link-local to the VPC, IPv6 does the egress.

Other requirements:

- **Public ECR over IPv6** — pull from the dual-stack endpoint
  `ecr-public.aws.com/<alias>/<repo>`, **not** the classic `public.ecr.aws`, which
  is IPv4-only and fails with "network unreachable". (For a *private* ECR repo,
  reference the dual-stack endpoint `<acct>.dkr-ecr.<region>.on.aws/<repo>`.)
- **ECS dual-stack setting** — requires the account setting `dualStackIPv6 = enabled`,
  created by this stack in `ecs.tf`.
- **Cloud Map SRV records** — API Gateway needs IP *and* port from
  `DiscoverInstances`; A/AAAA records carry only the IP. SRV carries both, so ECS
  registers `AWS_INSTANCE_IPV4` + `AWS_INSTANCE_PORT`.

## No container logs (on purpose)

There is no `logConfiguration` on the task. On a dual-stack task the `awslogs`
driver connects to CloudWatch over IPv4, and this subnet has no IPv4 egress, so
the driver times out and the task never leaves PENDING
(`ResourceInitializationError: failed to validate logger args`). Dropping the log
config lets the task start.

If you want logs without a NAT gateway, add a **CloudWatch Logs dual-stack
interface VPC endpoint** (~$7/mo) and put the `awslogs` config back. That keeps log
traffic private and on IPv6.

## Deploy

Requires [OpenTofu](https://opentofu.org) and AWS credentials.

```sh
tofu init
tofu apply
```

Then open the URL:

```sh
curl "$(tofu output -raw url)"
```

A successful run serves the cost-estimate page, confirming the full path:
API Gateway -> VPC Link -> Cloud Map (IPv4 target) -> Fargate task.

## Teardown

```sh
tofu destroy
```

Note: `destroy` disables — but does not delete — the account-level `dualStackIPv6`
setting, and that setting is account/region-wide, not scoped to this stack.

## Known sharp edges

- **ECS Exec** is not supported in IPv6/dual-stack-only egress setups the same way;
  and with no IPv4 egress, anything the container calls at runtime must reach a
  **dual-stack (IPv6) endpoint**. An IPv4-only dependency would need DNS64 + NAT64
  (a NAT gateway), which defeats the cost goal.
- The replacement of the Cloud Map service (e.g. changing record type) fails while
  a task is still registered. Scale the ECS service to 0 first, then apply.
