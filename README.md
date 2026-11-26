# Trends N Solutions ($TNS)

<p align="center">
  <img src="./logos/tns_logo_256x256.png" alt="Trends N Solutions ($TNS) Logo" width="140" />
</p>

Official smart contracts, verification test suite, metadata schemas, and brand identity assets for **Trends N Solutions (`TNS`)** on **Base Mainnet (Chain ID: `8453`)**.

---

## Verified On-Chain Deployment (Base Mainnet)

| Parameter | Verified Value |
| :--- | :--- |
| **Asset Name / Symbol** | **Trends N Solutions** / **`TNS`** (`18` decimals) |
| **Network** | Base Mainnet (Chain ID `8453`) |
| **Contract Address** | [`0x7841B0580ff8047063Fe8974D5A157690b8694Ad`](https://basescan.org/address/0x7841B0580ff8047063Fe8974D5A157690b8694Ad#code) |
| **Total Supply** | `10,000,000,000` (`10B TNS` — permanently fixed, zero minting, zero burning) |
| **Uniswap V2 Pair (`TNS/WETH`)** | [`0x2dA4D88601d8A2154F84b6cA84F76EEb1099b68E`](https://basescan.org/address/0x2dA4D88601d8A2154F84b6cA84F76EEb1099b68E) |
| **LP Lock Status** | **100% Permanently Burned** (`0x0000...dEaD`) — [Burn Tx Proof](https://basescan.org/tx/0x426d04c5338e53ace1a4ca90b81350bb324cd25607673c5581ac3bc608de236b) |
| **Compiler / EVM** | Solidity `v0.8.39+commit.ce47f2c8`, Optimizer `200` runs, `shanghai` |
| **Official Portal** | [https://tns.trendsnsolutions.com](https://tns.trendsnsolutions.com) |
| **Corporate Website** | [https://trendsnsolutions.com](https://trendsnsolutions.com) |
| **ERC-7572 `contractURI()`** | [https://tns.trendsnsolutions.com/metadata.json](https://tns.trendsnsolutions.com/metadata.json) |
| **Token List JSON** | [https://tns.trendsnsolutions.com/tokenlist.json](https://tns.trendsnsolutions.com/tokenlist.json) |

---

## Core Architecture & Safety Invariants (`contracts/TNS.sol`)

* **Fixed Cap (No Inflation):** Total supply of `10,000,000,000 * 10^18` minted once in `constructor()`; no `mint()` or `burn()` methods exist.
* **Hardcoded `1.00%` Tax Ceiling:** `MAX_TAX = 100` (100 bps) enforced on-chain; buy/sell taxes can never exceed `1.00%`, transfer tax is `0.00%`, and tax changes require a **24-hour public timelock** (`TIMELOCK_DELAY = 24 hours`).
* **Permanent Zero-Tax Switch:** Owner can irreversibly call `permanentlyDisableTax()` (`buyTax = 0`, `sellTax = 0`) when transitioning to `0%` fee DEX v3/v4 pools and Tier-1 exchange listings.
* **Anti-Honeypot Design:** Deliberately excludes `blacklist()` and `pause()` mechanisms; selling is never capped or delayed (`limitsInEffect` applies strictly to buys/wallet accumulation and can only increase or be permanently removed via `removeLimits()`).
* **Universal 5-Wallet Treasury Router:** Pull-payment ETH accounting (`pendingTreasuryETH`) with Gnosis Safe compatibility and vault fallback (`autoSplitEnabled`).
* **EIP-2612 Gasless Permit & ERC-7572 Metadata:** Supports off-chain permit signatures (`permit()`) and verifiable `contractURI()` branding.
* **Accidental Renounce Protection (`Ownable2Step`):** Direct `renounceOwnership()` is disabled to preserve operational safety and support clean multi-sig handoff (`transferOwnership` -> `acceptOwnership`).
* **Future L1 Migration Hook:** Dormant non-custodial escrow bridge (`setMigrationActive` / `migrateToNativeChain`) for future Layer-1 expansion.

---

## Supply Allocation & Public Wallets

| Allocation | Share | Amount (`TNS`) | Verified Base Address |
| :--- | :---: | ---: | :--- |
| Uniswap V2 Pool (`TNS / WETH`) | **70%** | `7,000,000,000` | [`0x2dA4D88601d8A2154F84b6cA84F76EEb1099b68E`](https://basescan.org/address/0x2dA4D88601d8A2154F84b6cA84F76EEb1099b68E) *(LP 100% burned)* |
| Engineering Development | **10%** | `1,000,000,000` | [`0x003B95aA11978d09809FEBe55B7e33Be8f824B30`](https://basescan.org/address/0x003B95aA11978d09809FEBe55B7e33Be8f824B30) |
| Marketing & Expansion | **10%** | `1,000,000,000` | [`0xA643095B3dcA96F8E421beC9982849e3Fa9e2447`](https://basescan.org/address/0xA643095B3dcA96F8E421beC9982849e3Fa9e2447) |
| Assets & Capital | **5%** | `500,000,000` | [`0x7b8492addF7797305E618A84cC734F6a63EB156B`](https://basescan.org/address/0x7b8492addF7797305E618A84cC734F6a63EB156B) |
| Founder Equity | **5%** | `500,000,000` | [`0x2EF83Dd45E3497Ba818Cc05180AFa7663F2514c0`](https://basescan.org/address/0x2EF83Dd45E3497Ba818Cc05180AFa7663F2514c0) |
| Central Capital Reserves *(Owner)* | **0%** | `0` | [`0x9B8E38A3010C704755DC39e6c1C9617EA93d85d0`](https://basescan.org/address/0x9B8E38A3010C704755DC39e6c1C9617EA93d85d0) |

---

## Reproducible Build & Verification (Foundry)

Compiler configuration in [`foundry.toml`](./foundry.toml):

```toml
solc = "0.8.39"
evm_version = "shanghai"
optimizer = true
optimizer_runs = 200
```

Run the complete test suite:

```bash
forge test -vvv
```

---

## Brand Assets & Metadata

* Official logo assets live in [`logos/`](./logos/) (`logo.png`, `128x128`, `256x256`, `512x512`, `1024x1024`).
* Contract metadata and token list definitions live in [`metadata/`](./metadata/).

---

## Verification & Links

* **Official X (Twitter):** [@TNS_Officials](https://x.com/TNS_Officials)
* **BaseScan Verified Source:** [View Code](https://basescan.org/address/0x7841B0580ff8047063Fe8974D5A157690b8694Ad#code)
* **DEXScreener Pair:** [View Pair](https://dexscreener.com/base/0x2da4d88601d8a2154f84b6ca84f76eeb1099b68e)
* **GeckoTerminal Pool:** [View Pool](https://www.geckoterminal.com/base/pools/0x2da4d88601d8a2154f84b6ca84f76eeb1099b68e)
* **Honeypot.is:** [Verify Simulation](https://honeypot.is/base?address=0x7841B0580ff8047063Fe8974D5A157690b8694Ad)
* **GoPlus Security:** [Inspect Security](https://gopluslabs.io/token-security/8453/0x7841B0580ff8047063Fe8974D5A157690b8694Ad)

---

**License:** MIT — see [`LICENSE`](./LICENSE).
