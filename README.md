# HedgeFundCore

## Contracts

- `HedgeFund`: ERC20 share token implementing queue-based liquidity, fee accrual, and epoch accounting. Management and performance fees are expressed in WAD and can be reconfigured by the owner.
- `Queue`: ERC721 enumerating tickets for pending deposits/withdrawals; ownership stays with the HedgeFund.

Key mechanics:
- **Management fee**: accrues continuously at `managementFeeWad` (default 2% yearly).
- **Performance fee**: charged only when the share price exceeds the stored High-Water mark. Profit above HWM is skimmed at `performanceFeeWad` (default 20% yearly). High-water mark updates on new net highs.
- **High-water mark**: persists through drawdowns; performance fees resume only after the previous peak NAV is surpassed.
- **Owner**: Safe Multisig of Altitude Hedge Fund. contributeEpoch uses Safe Multisig to indicate the current Net Asset Value. Altitude Hedge Fund invests in a variety of strategies, strategies may change frequently, NAV is considered off-chain.

Fee math uses pure WAD formulas, avoiding loops or redundant transfers, and works with any asset up to 18 decimals (scaling is derived at deployment).

## System

```
 Depositor            HedgeFund (ERC20 share)            Owner
    |                       |                              |
    | deposit(assets)       |                              |
    |---------------------> | mint Queue NFT (deposit)     |
    |                       v                              |
    |                  Queue (ERC721)                      |
    |                       |                              |
    |       claim() burns NFT, mints shares                |
    |<--------------------- |                              |
    |                       | contributeEpoch(nav)         |
    |                       |<-----------------------------|
    |                       |-- fee shares minted -------->|
    | withdraw(shares)      |                              |
    |---------------------> | mint Queue NFT (withdraw)    |
    |                       v                              |
    |       claim() burns NFT, redeems assets              |
    |<--------------------- |                              |
```

## Development

```bash
forge install

# fork mainnet for USDT metadata
forge test
```

## Deployment

The deployment script expects environment variables describing ownership, assets, and token metadata:

```bash
export HEDGE_FUND_OWNER=0xSafeMultisig
export HEDGE_FUND_ASSET=0xTokenAsset
export HEDGE_FUND_SHARE_NAME="Altitude Hedge Fund Share"
export HEDGE_FUND_SHARE_SYMBOL="AHFS"
export HEDGE_FUND_QUEUE_NAME="Altitude Hedge Fund Queue"
export HEDGE_FUND_QUEUE_SYMBOL="AHFQ"

forge script script/DeployHedgeFund.s.sol:DeployHedgeFund \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_KEY \
  --broadcast
```