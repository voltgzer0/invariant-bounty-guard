# Invariant Bounty Guard

> A defensive Solidity primitive that turns an attack on your accounting invariant into a paid bug report — atomically, on the same transaction, before the attacker can extract funds.

**Status**: production-grade reference implementation. Available for integration, licensing, and audit-firm partnerships.

---

## What it does

Most DeFi exploits follow one pattern: an attacker finds a way to break an accounting invariant (`sum(balances) == totalSupply`, `contractBalance >= totalLiabilities`, etc.), then drains funds through the gap.

`InvariantBountyGuard` wraps every settlement-class function in a **two-frame revert/catch**:

1. The outer frame snapshots the invariant magnitude.
2. The body executes inside an inner self-`delegatecall`. After the body, the inner asserts the invariant.
3. **If the invariant breaks, the inner frame reverts** — the EVM rolls back the body's state changes atomically.
4. The outer frame catches the revert, decodes the breach magnitude from revert data, **pays a bounty to the original caller**, and trips a conditional pause.
5. A DoS guard prevents false-trigger attempts (a probe of an already-broken invariant produces no delta → no payout, no pause).

The economic result: an attacker who would have drained $10M now earns a fixed bounty (e.g. 1 ETH), the protocol loses 1 ETH instead of everything, and the attack is converted into a paid whitehat report on the same block.

## Live numbers (anvil, fresh chain)

Captured from the included verification suite, executed against a real EVM:

```
[breach] prober calls brokenWithdraw(50) on a vault with 100/100 supply/liabilities
status               1 (success)            ← outer caught the breach
gasUsed              106515

[post] totalSupply       = 100              ← state rolled back atomically
[post] totalLiabilities  = 100
[post] balanceOf(prober) = 100
[post] paused            = true             ← conditional pause tripped
[post] pendingBounty     = 1 ETH            ← reporter credited
[post] totalEscrow       = 4 ETH            ← escrow debited

[claim] prober ETH after = +1 ETH           ← pull-pattern payout

[probe] same call against an already-broken invariant
[post] paused            = false            ← DoS-resistance: zero state delta = no pause/payout
```

Four Foundry property tests covering honest path, real breach, false-trigger DoS, and reentrancy on payout — all passing.

```
[PASS] test_honestWithdraw_passes_noPayout_noPause          (gas: 196,020)
[PASS] test_breach_rollsBackState_paysReporter_pauses       (gas: 338,268)
[PASS] test_falseTrigger_noPayout_noPause                   (gas: 201,505)
[PASS] test_reentrancy_on_claimBounty_blocked               (gas: 586,437)
```

## Threat model summary

| Vector | Mitigation |
|---|---|
| Body state changes persist after breach | Inner frame runs the entire body via `delegatecall`; revert rolls back EVM-level. |
| Reporter identity erased by self-call | `delegatecall` preserves `msg.sender`; reporter is the original external caller. |
| False-trigger DoS (probe of pre-existing breach) | Pre/post magnitude snapshot; `_onBreach` no-ops when delta is zero. |
| Reentrancy on bounty payout | Pull-pattern (`pendingBounty` + `claimBounty`) with CEI ordering + `nonReentrant`. |
| Non-invariant revert in body swallowed as breach | Outer frame decodes revert data; only the `InvariantBreach(uint256)` selector triggers payout, everything else is re-raised verbatim. |
| Under-funded escrow blocks pause | Pause trips regardless of payout success — security takes priority over revenue. |

## Public interface

[`IInvariantGuard.sol`](src/IInvariantGuard.sol) — the full external surface. NatSpec'd, audit-ready signatures.

Implementation is delivered under license. Reach out below.

## Extension: third-party-sponsored bounty escrow

[`IBountyVault.sol`](src/IBountyVault.sol) — the interface for sponsoring a bounty on an `InvariantGuard`-protected target you do not control.

The standard pattern collapses target, escrow, and payout into one contract — works when the protocol funds its own bounty, blocks third parties (audit firms, ecosystem programmes, insurance pools) from underwriting a target's invariant. `IBountyVault` is the cleanest split:

```
sponsor  ──fund──▶  BountyVault  ◀──notifyBreach──  guarded target
                          │
                          └─ pendingBounty[reporter]  ──claim──▶  reporter
```

Properties:

- Sponsor whitelists which targets can trigger payouts.
- Targets can only credit reporters, never withdraw escrow directly.
- Pull-pattern claims; payout is atomic with the breach event.
- Sponsor can revoke a misbehaving integration; pending credits earned beforehand are preserved.
- Target's pause / rollback semantics remain unchanged; the escrow lives elsewhere.

Pair with the `BountyConnectorGuard` variant of `InvariantGuard` to wire a target into this escrow. Implementation delivered under license.

## Who this is for

- **DeFi protocols** with accounting invariants — vaults, lending, AMMs, perps, RWA, stablecoin issuers.
- **Audit firms** wanting a post-audit safety net to bundle with engagements.
- **L1 / L2 ecosystems** funding defensive infrastructure as a public good.

## Licensing & integration

The interface is published under MIT for inspection.

The implementation, monetization layer (`Marketplace`, `RevenueShareGuard`), and integration support are commercial. Tiered structure for individual protocols, audit firms (whitelabel), and ecosystem partners.

Reach out for:

- a sample integration against your existing contracts,
- a license quote,
- audit-firm partnership terms.

## Author

Built by [voltgzer0](https://github.com/voltgzer0) — part of the **Voltgzer0 Labs Ltd** security portfolio.

Contact: [X](https://x.com/voltgzer0) · [Telegram](https://t.me/voltgzer0) · [Cantina](https://cantina.xyz/u/voltgzer0) · `voltmattty77@gmail.com` · [GitHub](https://github.com/voltgzer0)

Prefer a public thread? Open an [issue](../../issues/new).

Whitehat. Available for integration, licensing, and audit-firm partnerships.

---

© 2026 voltgzer0. All rights reserved on the implementation. Interface released under MIT.
