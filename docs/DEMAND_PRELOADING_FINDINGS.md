# Demand-based preloading: official Darkbloom 0.9.9

Reviewed against Darkbloom source `b6f9574ed40a5e1f8b8fb288224ea3de88d1be98` and Darkbloom Control base `f9b65d1` on 2026-09-25 (America/Phoenix). This is a feasibility assessment; no warm-up inference or provider mutation was performed.

## Finding

An ordinary inference request can cause an advertised, nonresident model to load. Exclusive self-route makes that request eligible only for providers owned by the authenticated account and prevents paid fleet fallback. It does not provide a dedicated preload operation, pin one particular Mac, or guarantee that existing idle models remain resident.

The distinction matters: a model listed by `GET /v1/models` is advertised/servable, not necessarily warm. The `model_not_loaded` self-route error also covers absent or ineligible advertised builds; its name alone is not proof that self-route requires a resident model.

## Evidence

| Question | Current official contract |
|---|---|
| Can self-route target a cold model? | Owner preflight checks the provider's advertised model list and eligibility. Dispatch can select a cold candidate; the provider inference handler calls `ensureModelLoaded`. This supports request-triggered loading in source, subject to admission and routing gates. It has not been exercised live in this audit. |
| Does it select this Mac? | `X-Darkbloom-Route: self` restricts by account ownership. Multiple eligible owned machines can satisfy it. Alias resolution may choose among eligible concrete builds. |
| Can it silently spend network credits? | Exclusive `self`, or a `self_route_only` key, has no paid fleet fallback. `prefer` does allow paid fallback and is unsuitable for unattended no-charge warming. Electricity and local resource use still apply. |
| Is there a more direct route? | Unified localhost chat shares the live provider's model slots. A tiny ordinary local completion can trigger the same load path on this Mac. Standalone local mode has its own slot cache and would not prove the network provider is warm. |
| Is there an official no-eviction warm endpoint? | None was found in the CLI, coordinator consumer routes, or pinned local server router. `allowEviction: false` exists internally for startup preload but is not an operator HTTP/CLI capability. |
| Can token tools warm it without generation? | The unified token utilities only resolve a tokenizer from an already resident slot. They take no load reservation and are not a warm-up API. |
| What might ordinary loading change? | It may evict an idle resident at slot or memory limits. Current provider code excludes in-flight work from eviction, but a separate app's preflight cannot atomically reserve spare capacity. |
| Is it persistent? | A successful request does not pin residency. Idle timeout, later work, memory admission, and coordinator decisions can change the resident set. |

## Recommended product sequence

1. **Demand recommendation:** rank only downloaded, saved-enabled models using fresh capacity data; show the signal and its age. Require sustained pressure across distinct samples so a brief spike does not trigger churn. Describe opportunity, not guaranteed earnings.
2. **Explicit Warm action:** if added, label it as a small inference request, show the exact route, require a current unified loopback endpoint to target this Mac, serialize with provider operations, and report potential idle-model eviction. Confirm success from new residency evidence for the same provider process.
3. **Optional automation:** keep disabled by default. Add a persistent cooldown, one request at a time, fresh memory/slot/config/demand gates, no action during drain or unapplied settings, a thermal ceiling, bounded token/output/time limits, and an activity log. Cancellation or an HTTP failure must trigger reconciliation because loading may already have happened.
4. **Stronger guarantee:** request an official provider capability for an atomic no-eviction load before promising spare-slot-only automatic preloading. Host-side memory estimates cannot supply that guarantee.

An exclusive network route can be an explicit remote warm request when account-level targeting is acceptable. For automatic warming of this Mac, verified unified localhost is the more precise target. Neither route currently exposes a no-eviction guarantee.

The historical [live model warming design](superpowers/specs/2026-09-03-live-model-warming-design.md) is explicitly superseded and describes rejected custom provider endpoints. It is not authority to restore those endpoints or deploy a modified provider.

## Pinned primary sources

- [Self-route policy and errors](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/api/self_route.go)
- [Owned-model advertisement checks](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/model_catalog.go)
- [Scheduler and owned-provider preflight](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/coordinator/registry/scheduler.go)
- [Provider inference load gate](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BInferenceHandler.swift)
- [Unified local acquisition and token utilities](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BLocalEndpoint.swift)
- [Model loading and eviction](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/provider-swift/Sources/ProviderCore/ProviderLoop%2BModelLoading.swift)
- [Pinned local HTTP router](https://github.com/Layr-Labs/mlx-swift-lm/blob/6f3d171fb7270ba18fb2432ab4f4aab5ed4b6114/Libraries/MLXLMServer/HTTP/MLXServerApplication.swift)
- [Official self-route documentation](https://github.com/Layr-Labs/d-inference/blob/b6f9574ed40a5e1f8b8fb288224ea3de88d1be98/docs/provider/self-route.md)
