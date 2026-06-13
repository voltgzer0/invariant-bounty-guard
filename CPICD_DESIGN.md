# CPICD — Cross-Protocol Invariant Cascade Detection

**Design specification, draft v0.1**
Extension of `InvariantBountyGuard` (`InvariantGuard.sol`)
Voltgzer0 Labs Ltd

---

## 0. One-line statement

> An on-chain mechanism that detects, within the *same transaction* as an exploit, whether a protocol's invariant breach has cascaded into a declared dependency — and atomically reverts the inner call frame while paying a bounty to the discoverer, before corrupted state can reach integrators.

---

## 1. Honest novelty positioning

This section exists so the claim survives a reviewer who will run the same search you did. **Do not overclaim — overclaiming is how a grant gets rejected.**

**What already exists (must be acknowledged):**

- **Circuit breakers** (Chainlink Proof-of-Reserve + Automation, protocol-level pause patterns). These react to *metrics* (price anomalies, reserve ratios, large liquidity moves) and operate with **block-level delay** or via **governance**. They are not atomic with the exploit transaction.
- **Cross-contract exploit detection** (DeFiTail, CrossInspector, EClone-family). These are **off-chain**, static / ML, and run **after** the fact. They classify; they do not prevent in-flight.
- **Single-protocol invariant assertion** — your own existing `InvariantGuard`, plus standard `require`-based invariant checks. These cover *one* contract's own state.

**What is NOT found in prior art (the defensible gap):**

- An **atomic, on-chain, same-transaction** check that walks a contract's *declared dependency guards*, asserts each dependency's invariant via `staticcall`, and — if any dependency's invariant is now broken as a downstream effect of the local call — reverts the inner frame and rewards the reporter, **all inside the EVM call frame of the exploit itself**.

**Correct framing for grant / capstone (true and defensible):**

> "Existing cascade defenses are *delayed* (circuit breakers fire next block / via governance) or *off-chain* (static analyzers run post-mortem). CPICD performs cascade detection *atomically*, at EVM-call-frame granularity, on-chain — the transaction either leaves every declared dependency invariant-healthy, or the whole thing reverts and is reported."

**Incorrect framing (will be destroyed by reviewers):**

> ~~"No one has solved cascading failures in DeFi."~~ — False. Circuit breakers exist. Never say this.

---

## 2. Background — the existing InvariantGuard mechanism

The current `guarded` modifier executes the function body inside an inner `delegatecall` frame, then asserts the *local* invariant:

```
modifier guarded() {
    // outer frame (_depth == 0)
    (bool ok, ) = address(this).delegatecall(msg.data);   // inner frame runs body
    if (!ok) {
        // inner frame reverted (incl. InvariantBreach) → EVM rolled back inner state
        _onBreach(...);        // credit bounty, set paused = true
    }
    // outer frame state (bounty accounting, pause) survives
}
```

Key properties this design relies on and must preserve:

1. **Two-frame separation.** The body runs in an inner frame. If it reverts, EVM discards inner state mutations; the outer frame keeps executing (bookkeeping, bounty, pause).
2. **`__assertInvariant()`** is called at the end of the inner frame and reverts with `InvariantBreach` if the local invariant does not hold.
3. **DoS guard `postMag != preMag`** in `_onBreach` — bounty pays only when the breach corresponds to a *real* state change, not a spurious assertion against an already-broken invariant.

CPICD adds a **dependency dimension** to step 2.

---

## 3. CPICD mechanism

### 3.1 Dependency declaration

An integrating contract declares the guards it depends on:

```solidity
interface IInvariantGuard {
    /// @notice Reverts with InvariantBreach() if this contract's invariant does not hold.
    /// MUST be view (no state mutation). Callers MUST invoke via staticcall.
    function __assertInvariant() external view;
}

abstract contract InvariantGuard is IInvariantGuard {
    /// @notice Declared dependency guards. Override in integrator.
    function _externalDependencies()
        internal
        view
        virtual
        returns (address[] memory);
}
```

### 3.2 Cascade assertion (the new step)

At the end of the inner frame, *after* the local `__assertInvariant()` passes, the guard walks declared dependencies:

```
// inner frame, _depth == 1, after local invariant holds
address[] memory deps = _externalDependencies();
for (uint256 i = 0; i < deps.length; ++i) {
    // staticcall — dependency CANNOT mutate state during the check
    (bool ok, ) = deps[i].staticcall{gas: PER_DEP_GAS_CAP}(
        abi.encodeWithSelector(IInvariantGuard.__assertInvariant.selector)
    );
    if (!ok) revert CascadeBreach(deps[i]);   // propagates to outer frame
}
```

A `CascadeBreach` reverts the inner frame exactly like a local `InvariantBreach`. The outer frame's existing `_onBreach` path fires: rollback of inner state is already done by EVM, bounty is credited, `paused = true`.

### 3.3 What gets rewarded

The reporter (the EOA / `tx.origin` of the exploit attempt, subject to the same DoS guard) is paid for **discovering a cascade** — i.e. the local protocol was technically healthy (`__assertInvariant` passed locally) but the call pushed a *declared dependency* into an invalid state. This is the novel reward surface: cascades that no single-protocol guard would catch.

---

## 4. Edge cases & attack surface — the core of the design

This is where the mechanism lives or dies. Each item is a way the naive version breaks, plus the mitigation that must ship.

### 4.1 Cyclic dependencies → infinite recursion → out-of-gas
**Attack / failure:** A declares B as a dependency; B declares A. A's cascade walk staticcalls `B.__assertInvariant()`; if that in turn walks *its* dependencies and reaches A, you recurse until gas exhaustion. A griefer can register a cycle to brick the guard.

**Mitigation:**
- `__assertInvariant()` MUST be **shallow** — it asserts *only the local invariant*, it does NOT recursively walk dependencies. The cascade walk happens **once**, in the originating guard's inner frame, and is **not re-entered** by dependency assertions.
- This makes the walk **one level deep by construction**. If multi-level cascade is desired later, it requires an explicit `visited` set passed across calls (much more complex — defer to v0.2, document as out of scope for v0.1).

> Decision: **v0.1 is depth-1 only.** One hop. This is a deliberate, documented limitation, not an oversight. Depth-1 already covers the dominant real case (A deposits into B; A's action breaks B).

### 4.2 State mutation during the check → manipulation
**Attack:** A malicious dependency's `__assertInvariant()` mutates state (e.g. resets a flag) so the check passes while the breach persists.

**Mitigation:** All dependency assertions invoked via **`staticcall`**. EVM forbids state mutation inside a static context; any `SSTORE` in a dependency's assert reverts the staticcall, which CPICD treats as `CascadeBreach` (fail-closed). Document: **assert functions reached via CPICD must be pure-view; non-view asserts are treated as breaches.**

### 4.3 Gas-griefing dependency → DoS of the host
**Attack:** A dependency's `__assertInvariant()` deliberately burns all forwarded gas (e.g. unbounded loop), making every guarded call on the *host* revert with out-of-gas. The host is now DoS'd by a contract it merely declared.

**Mitigation:**
- **`PER_DEP_GAS_CAP`** — forward a bounded gas stipend per dependency staticcall. If the dependency exhausts it, the staticcall fails → `CascadeBreach` → host reverts *that* transaction but is not permanently bricked, and the offending dependency is identifiable from the `CascadeBreach(dep)` event.
- **Bounded `deps.length`** — cap the number of declared dependencies (e.g. `MAX_DEPS`). Unbounded dependency arrays are themselves a gas-DoS vector.
- Open question: should a repeatedly-failing dependency be auto-evicted? (Governance vs automatic — defer, document.)

### 4.4 Upgradeable-proxy dependency → stale invariant
**Attack / failure:** A dependency is an upgradeable proxy. Its implementation changes; the new logic has a different invariant, but `__assertInvariant()` still points at logic that no longer reflects reality. CPICD asserts a meaning that is stale.

**Mitigation (honest — this one is hard):**
- CPICD cannot guarantee a proxy's assert reflects its current implementation. Document this as a **known limitation**, not a solved problem.
- Partial defense: dependencies MAY expose an `invariantVersion()` and the host MAY pin an expected version, reverting if it drifts. This converts a silent stale-assert into a loud, attributable revert — which is "a better problem than no detection," but is not a full fix.
- Reviewer-honest statement: *"CPICD's guarantee is scoped to dependencies whose `__assertInvariant` faithfully reflects current implementation. Proxy drift is a documented residual risk; version pinning reduces but does not eliminate it."*

### 4.5 Non-conforming external protocols (the adoption problem)
**Reality:** Aave, Uniswap core, etc. do NOT implement `IInvariantGuard`. Without adoption, the declared-dependency set is empty for the protocols that matter most.

**Mitigation — adapter pattern:**
- A `DependencyAdapter` wraps a non-conforming protocol and implements `__assertInvariant()` as a **proxy-invariant**: it reads observable surface (e.g. `totalSupply`, `balanceOf(pool)`, a price/reserve ratio) and asserts a delta bound or a sanity relation.
- This is weaker than a native invariant (it is a *heuristic* proxy, not the protocol's true invariant) and must be labelled as such. A proxy-invariant can have false negatives (cascade that doesn't move the observed surface) and false positives (legitimate large move).
- **This is the honest ceiling of the design:** CPICD is strongest between *cooperating* guarded protocols, and degrades to best-effort heuristic against *non-cooperating* ones. Say this plainly in the grant.

### 4.6 Bounty gaming
**Attack:** Someone artificially induces a (cheap, self-inflicted) cascade to farm the bounty.

**Mitigation:**
- Reuse the existing `postMag != preMag` DoS guard, extended to the dependency surface: bounty pays only if the dependency's *state magnitude* actually changed as a result of the call — not if the dependency was already broken before the call, and not if the "breach" is a no-op.
- Cooldown / per-reporter rate limit on cascade bounties.
- Bounty funded from a bounded pool (`fund()` / pull-over-push already exists) — a drained pool caps maximum loss from gaming.

### 4.7 Reentrancy interaction
**Note:** Because all dependency asserts are `staticcall` + view, they cannot reenter with state changes. The existing `ReentrancyGuard` on the host still protects the outer frame's bounty accounting. Confirm: the cascade walk runs *after* the body but *before* the inner frame returns, so no external mutable call happens between assert and rollback.

---

## 5. Gas profile (order-of-magnitude, to be measured)

| Component | Cost |
|---|---|
| Local `__assertInvariant` | unchanged from current IBG |
| Per-dependency `staticcall` | warm/cold account access + dependency's own view cost, capped at `PER_DEP_GAS_CAP` |
| Cascade walk | `O(deps.length)` external staticcalls, `deps.length <= MAX_DEPS` |

The walk only runs on guarded entrypoints. For typical `MAX_DEPS` in the 2–5 range, overhead is a handful of staticcalls per guarded call. **Must be benchmarked in Foundry against real dependency asserts — do not ship gas claims without measured numbers.**

---

## 6. What this is NOT (scope discipline)

- Not a replacement for circuit breakers (those handle *metric* anomalies CPICD cannot see).
- Not a recursive/transitive risk graph (that's depth-N, deferred).
- Not protection against dependencies that lie via upgradeable proxies (residual risk, documented).
- Not effective against non-cooperating protocols beyond heuristic adapters.

**v0.1 known property — CascadeSuspect vs CascadeBreach:**
A dependency that breaks its invariant but reverts *without a payload* (bare `revert()`, OOG exhaustion, or EVM-level abort such as SSTORE under staticcall) is classified as `CascadeSuspect`, not `CascadeBreach`. The guarded transaction is still rolled back — fail-closed is preserved and the attack does not go through. However, the host is NOT paused and no bounty is paid. Full cascade detection (pause + bounty) requires the dependency to revert with a non-empty payload, as a conforming `IInvariantGuard` implementation always does (`InvariantBreach(uint256)`). This distinction is intentional: an empty-payload failure is ambiguous — it could be gas griefing or a buggy dep — and must not let an adversarial dependency freeze the host. Known property, not a bug.

Naming these *before* a reviewer does is what makes the rest credible.

---

## 7. Path to capstone / grant

1. **Implement depth-1 CPICD** on top of existing `InvariantGuard` — the cascade walk + `CascadeBreach` + staticcall + gas cap + `MAX_DEPS`.
2. **Foundry test matrix:**
   - Cooperating dependency, real cascade → reverts + bounty paid + dependency identified.
   - Cooperating dependency, healthy → passes, no overhead beyond walk.
   - Cyclic declaration → does NOT recurse (proves depth-1 invariant).
   - Gas-griefing dependency → host reverts that tx only, dependency attributable, host not bricked.
   - State-mutating assert → treated as breach (staticcall fails closed).
   - Bounty-gaming attempt → blocked by `postMag != preMag` + cooldown.
3. **Reproduce a historical cascade** (e.g. a documented multi-protocol incident) in a Foundry fork test, showing CPICD would have reverted the originating tx. *This single test is the most persuasive grant artifact you can produce* — a concrete "this exploit would have been caught atomically."
4. **Write-up** with the honest novelty framing from §1.

---

## 8. Open questions (resolve before building)

- `__assertInvariant` selector collision risk if a dependency implements the selector with different semantics — require explicit opt-in registry of conforming guards?
- Should declared dependencies themselves be required to be registered (echo of the RRC weakness — avoid self-reported trust)? Likely yes: **dependencies must be in an allowlist the host controls**, so a host cannot be tricked into trusting an attacker-chosen "dependency."
- Event schema for `CascadeBreach` — must carry enough for off-chain forensics (dependency addr, selector, block, reporter).

---

*Draft for design review. Nothing in here is committed to the codebase. Gas figures and novelty claims are unverified until Foundry-measured and re-searched at implementation time, respectively.*
