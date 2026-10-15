# AHyperQuoteHook

A Uniswap v4 hook on Monad that lets holders of aHYPER (an Accountable vault share) sell it instantly for USDC to a
single market maker, at the share's live on-chain `sharePrice()` minus a discount the maker sets. The maker's USDC stays
deposited in a MetaMorpho vault and earns yield until a swap needs it; inside the swap the hook withdraws exactly the
USDC it pays out of the maker's vault position.

Status: fork-tested, **not deployed**.

## Pricing

The hook serves one canonical pool: {USDC, aHYPER} sorted, static LP fee 0, tickSpacing 1, this hook. Only one
direction fills: the swapper sells aHYPER for USDC, exact-input or exact-output. A swap that buys aHYPER reverts with
`AskNotOffered`.

| | |
|---|---|
| Price per aHYPER | `sharePrice() x (10,000 - discountBps) / (precision() x 10,000)` USDC |
| Ceiling | the realised fill never pays more than `sharePrice() x MAX_BID_BPS / 10,000` |
| Rounding | in the maker's favour: exact-in rounds the USDC out down, exact-out rounds the aHYPER in up |

`sharePrice()` is computed by the vault's strategy from the loan's interest accrued to `block.timestamp`, so it rises
every second and no off-chain quote or signature is needed. Routers pass empty `hookData`. `beforeSwap` (with
`beforeSwapReturnsDelta`) fills the whole swap, so the AMM amount is always 0: the pool's `sqrtPriceX96` is never used,
liquidity added to the pool is never traded, and no v4 protocol fee can apply (`Pool.swap` returns before any fee when
the amount is 0).

## Maker parameters

`setParams(Params p, uint128 expectedRemaining)`, maker only:

| Field | Meaning |
|---|---|
| `validUntil` | last timestamp at which the bid fills; 0 disables it |
| `discountBps` | discount to `sharePrice()` |
| `remaining` | aHYPER base units the hook still buys; 0 disables it |

`validUntil = 0` or `remaining = 0` is the kill switch: it skips every check, so it works even while the share or its
strategy reverts. Opening or changing a live bid requires `expectedRemaining` to equal the stored `remaining`, so a fill
that lands between the maker reading the bid and re-posting it makes the re-post revert (`RemainingChanged`) instead of
being bought again. It also requires the strategy to be unpaused with its loan ongoing, aHYPER to be transferable, `sharePrice() > 0`,
`discountBps < 10,000` and `10,000 - discountBps <= MAX_BID_BPS`.

## Checks on every fill

- the pool is the canonical pool and the swapper sells aHYPER;
- `block.timestamp <= validUntil` and the amount fits in `remaining`;
- the strategy is not paused and aHYPER is transferable. Either condition already blocks aHYPER ERC-20 transfers, so
  router sales revert anyway; the check also stops sales paid with aHYPER already held in the PoolManager (ERC-6909
  claims);
- the strategy's `loanState()` is `OngoingLocked` (2) or `OngoingDynamic` (3). Fills stop in the block the state leaves those values; in the current strategy implementation only `acceptDefault()` (to InDefault) and repayment to zero (to Repaid) do that, and `rejectTerms()` changes nothing once the loan is ongoing. A default is initiated by `defaultLoan()` at least one day before `acceptDefault()` can flip the state; during that window `sharePrice()` keeps accruing and the hook cannot see it (`_defaultValidAt` has no getter). The maker's bot must kill the bid while a default is pending.
- `sharePrice() > 0`, the USDC out is not 0, and the ceiling holds on the realised amounts.

## Settlement

1. Routers settle the seller's input after the swap returns, so the hook `mint`s an ERC-6909 aHYPER claim to itself,
   backed by that settlement in the same transaction.
2. The hook runs `sync(USDC)`, `VAULT.withdraw(amountOut, PoolManager, MAKER)` and `settle()`. MetaMorpho pulls the
   USDC from its withdraw queue; if its markets lack the liquidity, the whole swap reverts and nothing moves.
3. `sweep()` is permissionless and moves everything the hook holds to `MAKER`: its aHYPER and USDC claims and any
   aHYPER or USDC sent to it directly. `sweep(currency)` does the same for one currency, so a currency that cannot move
   (aHYPER while the strategy is paused) never strands the other.

## Safety properties

- No owner, not upgradeable; every address is immutable.
- Value only moves to `MAKER` (swept claims) or from the maker's vault position to the PoolManager for the fill.
- The maker's only approval is MetaMorpho shares to the hook. Its size bounds the USDC the hook can ever pay.
- The constructor requires the vault's asset to equal the share's asset, so the hook cannot pay in a token the share is
  not denominated in.

## Known limits

- A caller that syncs and pays before `swap` and settles afterwards reverts with `CurrencyNotSettled`. No value is lost;
  the UniversalRouter's V4Router is unaffected.
- aHYPER transfer restrictions. The vault's `permissionLevel` is fixed at construction (None) and the vault is not a
  proxy, so whitelist and KYC checks cannot arise. The strategy's manager can switch `transferableShares` off
  (`setSharesTransferable`); the hook then refuses every fill and every opening, including sales paid with aHYPER
  already in the PoolManager, and `sweep(aHYPER)` reverts until transfers reopen while `sweep(USDC)` still works.
- A pending default does not stop fills on-chain, so the maker's bot must kill the bid on it: after `defaultLoan()`
  (`LoanDefaultInitiated`) the state stays ongoing until `acceptDefault()`, at least 1 day later, and the pending
  default has no public getter (it lives in the private `_defaultValidAt`; the bot reads its storage slot).
  Delinquency (`DelinquencyStatusChanged(true)`, `_isDelinquent()`) is not on the list: it flags vault liquid assets
  below the strategy's required reserve, and it has been set while the vault operated normally.
- Fills depend on the funding vault's liquidity. A vault that lends into a highly utilised market, such as the Morpho
  aHYPER/USDC market, has the least liquidity exactly when exits peak.
- The price follows the strategy's `sharePrice()`; the strategy is an upgradeable proxy. A wrong price within the
  ongoing states is not detected on-chain; the maker's bot stops the bid with the kill switch. Its kill list: a pending
  default, a strategy implementation other than the one it was verified against (`Upgraded`), and a `sharePrice()`
  decrease or a jump beyond its threshold (a fulfilled redemption claimed late can step the price up slightly, toward the true share
  value).

## Notes for the maker's bot

- Kill with `remaining = 0`, not only `validUntil = 0`: a later open then needs `expectedRemaining = 0`, so an update
  prepared before the kill cannot reopen the bid.
- To re-price or resize a live bid that is being filled, kill first and then open with `expectedRemaining = 0`. Once
  `remaining` is 0 fills revert, so it cannot change underneath the open. A plain re-post can keep reverting
  `RemainingChanged` while fills land; treat that as re-read and retry, never as fatal.
- Kill on a pending default, an `Upgraded` strategy proxy, and a `sharePrice()` decrease or a jump beyond the bot's
  threshold. Sweep after fills and count unswept aHYPER claims as the maker's.

## Tests

```bash
git submodule update --init --recursive
export MONAD_RPC_URL=<Monad mainnet RPC>
forge test
```

Monad mainnet fork at block 113,335,000; 41 tests:

- fills through the mainnet UniversalRouter with Permit2 and empty `hookData`, exact-in and exact-out, at the discount
  and at the ceiling, with expected amounts computed independently from the formulas above;
- the price follows `sharePrice()` over time;
- direction, expiry, `remaining`, kill switch, every non-ongoing loan state, zero price, dust, parameter bounds, access
  control, wrong pool (at initialise and at swap), constructor config; a killed bid reverts before calling the strategy;
- a real strategy pause, and a real switch-off of aHYPER transfers, each stop a sale paid from PoolManager-held
  aHYPER and refuse to open a bid, while the kill switch and `sweep(USDC)` still work; a stale `expectedRemaining` makes a re-post revert;
- the fill-level ceiling holds even with a discount written straight into storage;
- a same-transaction redeem request (deposits are capped at the block) leaves the fill unchanged;
- funding bounded by the share allowance and by the maker's position; with the vault lending into a borrowed market, a
  fill up to the market's free liquidity succeeds and one base unit more reverts as a whole;
- sweep of claims and stray tokens, maximum protocol fee taking nothing, liquidity added and never traded, V4Quoter
  parity, a pool front-run-initialised at the minimum and maximum price.

Each guard in the hook was removed or altered one at a time (32 mutants); every mutant fails at least one test.

## Addresses (Monad mainnet, chain 143)

| | |
|---|---|
| PoolManager | `0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e` |
| UniversalRouter | `0x0D97Dc33264bfC1c226207428A79b26757fb9dc3` |
| aHYPER (Accountable vault share) | `0x7Cd231120a60F500887444a9bAF5e1BD753A5e59` |
| aHYPER strategy | `0xD0943c76ee287793559c1dF82E5B2B858Dd01Ef3` |
| USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` |
| Funding vault | MetaMorpho "Hyperithm USDC Apex" `0xA8665084D8CD6276c00CA97Cbc0BF4BC9ae94c79` |
| Hook permissions | `beforeInitialize`, `beforeSwap`, `beforeSwapReturnsDelta` (address mask `0x2088`) |
