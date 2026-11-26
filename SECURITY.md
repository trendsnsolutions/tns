# Security Policy — Trends N Solutions ($TNS)

## Smart Contract Security Design (`contracts/TNS.sol`)

* **Supply Invariant:** `10,000,000,000 * 10^18` fixed total supply (`_totalSupply` constant). No `mint()` or `burn()` functions exist.
* **Tax Ceiling Invariant:** `MAX_TAX = 100` (1.00% maximum buy/sell fee); transfer tax between non-AMM addresses is `0.00%`. All tax adjustments enforce `TIMELOCK_DELAY = 24 hours`. Tax can be permanently disabled via `permanentlyDisableTax()`.
* **Liquidity Lock:** 100% of initial Uniswap V2 LP (`28,982.753492378877146437 UNI-V2` on pool `0x2dA4D88601d8A2154F84b6cA84F76EEb1099b68E`) is permanently burned to `0x000000000000000000000000000000000000dEaD` (tx: `0x426d04c5338e53ace1a4ca90b81350bb324cd25607673c5581ac3bc608de236b`).
* **Anti-Honeypot & User Protections:**
  * No `blacklist()` or trading `pause()` functionality.
  * `limitsInEffect` restricts only max buy (`maxTxAmount`) and max non-exempt wallet balance (`maxWalletAmount`), strictly monotonically non-decreasing (`updateLimits` can only increase caps) and permanently removable (`removeLimits()`).
  * `recoverForeignToken()` explicitly prohibits recovering native `$TNS` (`require(tokenAddress != address(this))`).
  * `Ownable2Step` prevents accidental ownership loss (`renounceOwnership()` is disabled).
  * Pull-payment treasury ETH accounting (`pendingTreasuryETH`) with `ReentrancyGuard` prevents transfer-path reentrancy and external-call failures.

## Automated Test Verification

All 50 tests across four Foundry suites (`TNSTest`, `TNSMasterVerificationTest`, `TNSCompleteControlsAuditTest`, and `TNSAll65FunctionsMatrixTest`) verify deployment invariants, access control, timelocks, limit monotonicity, reentrancy/treasury routing, and L1 migration escrow.

## Reporting a Security Issue

To report a potential vulnerability in the contract, metadata endpoints, or official web portal (`https://tns.trendsnsolutions.com`), please contact:

* **Email:** `info@trendsnsolutions.com`
* **Website:** [https://trendsnsolutions.com](https://trendsnsolutions.com)

Please do not disclose unpatched vulnerabilities publicly prior to coordinated review.
