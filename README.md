# RecyclingEngine

**Deterministic execution primitive for irreversible ERC-20 unit consumption, native fee routing, and normalized accounting weight generation.**

---

## Definition

`RecyclingEngine` consumes accounting units registered in an external registry, accepts native execution fees, mints normalized accounting weight, and distributes native value proportionally through deterministic ledger math.

All state transitions are enforced on-chain.

---

## What This Contract Does

- Verifies asset eligibility via registry  
- Consumes accounting units from `SponsorshipLedger`  
- Routes native execution fees through a fee router  
- Mints accounting weight based on a defined price curve  
- Tracks proportional distribution via `accNativePerWeight`  
- Emits verifiable execution and claim events  

### Core Entrypoints

- `recycle(address token)` *(payable)*  
- `claim()`  
- `quoteUnitsToConsume(address token, uint256 nativeWei)`  
- `quoteNativeForUnitsCeil(address token, uint256 units)`  

---

## What This Contract Does NOT Do

- Does **not** promise yield, profit, or compensation  
- Does **not** transfer asset ownership  
- Does **not** custody ERC-20 tokens  
- Does **not** determine asset listing  
- Does **not** manage treasury  
- Does **not** guarantee outcomes  

This is an execution surface only.

---

## Scope Limitation

`RecyclingEngine` does not operate independently.

It relies on:

- **Registry** — asset configuration and eligibility  
- **SponsorshipLedger** — accounting unit tracking  
- **Router** — fee rail distribution  

---

## Deployment Status

- **Ownership:** Set per deployment  
- **Parameter control:** Owner-settable  
- **Upgradeability:** Non-upgradeable  
- **Immutability:** Final after `renounceOwnership()`  

Refer to GitBook for verification and deployed addresses.

---

## Documentation

Full documentation:

https://docs.modulexo.com
