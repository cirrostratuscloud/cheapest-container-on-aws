# Cost estimate — cheapest always-on public container on AWS

Proof of concept: what does it cost to keep a single publicly-reachable container
running on AWS, dialed down to the minimum, with no always-on infrastructure tax?

## Assumptions

- Region: **us-east-1**
- Task size: **0.25 vCPU / 0.5 GB** (smallest Fargate config), running **24/7 (~730 hrs/mo)**
- Traffic: **1,000 page views / month**
- Compute: **ARM64 (Graviton) on Fargate Spot**

The headline: cost is driven by **container uptime, not traffic**. 1,000 views is a
rounding error — the bill is essentially "what it costs to keep one tiny container
alive." That's the whole point of the exercise.

## Unit prices (us-east-1)

| Resource | On-demand | ARM (~20% off) | ARM Spot (~70% off) |
|---|---|---|---|
| Fargate vCPU / hour | $0.04048 | $0.032384 | $0.0097152 |
| Fargate memory GB / hour | $0.004445 | $0.003556 | $0.0010668 |
| API Gateway HTTP API | $1.00 / million requests | — | — |

## Monthly total @ 1,000 views (ARM Spot)

| Component | Basis | USD / mo |
|---|---|---:|
| Fargate vCPU | 0.25 × 730 × 0.04048 × 0.8 × 0.3 | 2.22 |
| Fargate memory | 0.5 × 730 × 0.004445 × 0.8 × 0.3 | 0.49 |
| Cloud Map (Route 53 hosted zone) | 1 private hosted zone × $0.50 | 0.50 |
| API Gateway HTTP API | 1,000 × $1 / million | 0.00 |
| VPC Link | no hourly charge (HTTP API) | 0.00 |
| Egress-only IGW | no charge | 0.00 |
| Data transfer out | negligible at 1k views | 0.00 |
| **Total** | | **~3.21** |

> **Note on Cloud Map:** a private DNS namespace creates a Route 53 private
> hosted zone on your behalf, billed at $0.50/mo (first 25 zones). It's the only
> fixed, always-on charge in the stack besides the container itself. DNS query
> charges are negligible at this scale.

## Comparison

| Setup | ~USD / mo |
|---|---:|
| ARM **Spot** (this stack) | **~3.21** |
| ARM on-demand Fargate | ~7.7 |
| x86 on-demand Fargate | ~9.5 |
| + NAT gateway (avoided) | +32 |
| + Load balancer (avoided) | +16 |

(All "this stack" figures include the $0.50 Cloud Map hosted zone.)

## Why ARM Spot

The goal is the cheapest public container, so we take every discount that doesn't
require a commitment:

- **ARM64 / Graviton**: ~20% cheaper than x86 at the same size, same nginx image
  (multi-arch pull).
- **Fargate Spot**: up to ~70% off on-demand. Tasks can be reclaimed with a 2-minute
  warning.
