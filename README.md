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
| Bid per aHYPER | `sharePrice() x (10,000 - discountBps) / (precision() x 10,000)` USDC, paid by the maker |
| Protocol fee | the pool's v4 protocol fee `f` (pips) for the sell direction, charged to the swapper in USDC |
| Swapper receives | exact-in: `bid - ceil(bid x f / 1e6)`; exact-out: the requested USDC, with `ceil(out x f / (1e6 - f))` added to the maker's payment and to the aHYPER in |
| Ceiling | the maker's payment never exceeds `sharePrice() x MAX_BID_BPS / 10,000` per aHYPER |
| Floor | the bid never falls below `sharePrice() x (10,000 - MAX_BID_DISCOUNT_BPS) / 10,000` per aHYPER |
| Rounding | in the maker's favour: exact-in rounds the USDC out down, exact-out rounds the aHYPER in up; the fee rounds up |

`sharePrice()` is computed by the vault's strategy from the loan's interest accrued to `block.timestamp`, so it rises
every second and no off-chain quote or signature is needed. Routers pass empty `hookData`. `beforeSwap` (with
`beforeSwapReturnsDelta`) fills the whole swap, so the AMM amount is always 0: the pool's `sqrtPriceX96` is never used
and liquidity added to the pool is never traded.

## Protocol fee

Because the AMM never swaps, the PoolManager would never charge the v4 protocol fee itself (`Pool.swap` returns before
any fee when the amount is 0). The hook charges it instead, following Uniswap's aggregator hooks
(`Uniswap/v4-hooks-public`, `aggregator-hooks/ProtocolFees.sol`):

1. read the pool's `protocolFee` from `getSlot0` and take the half for the swap direction (`getOneForZeroFee` for a
   sell of aHYPER, which is currency1);
2. resolve the recipient as `protocolFeeController().TOKEN_JAR()` (Uniswap's `V4FeeAdapter`);
3. compute the fee on the USDC side, rounded up, have the maker's vault pay bid + fee into the PoolManager, and
   `take` the fee to the TokenJar inside the swap, emitting `ProtocolFeesCollected(jar, USDC, fee)`.

Nothing is charged when the fee is 0, when the controller has no code, or when `TOKEN_JAR()` reverts, runs out of its
50,000 gas, returns under 32 bytes, or returns a word that is not a non-zero address. The call copies back one word
only, so no gas-burning, oversized or malformed answer can block fills; a controller that names a TokenJar the asset
refuses to pay (for example a blacklisted address) still makes fills revert while the fee is nonzero, until
governance replaces the controller or sets the pool's fee to 0. Uniswap's
V4FeeAdapter on Ethereum (`0x89A5D5bF00a27D55c02951E49078a5C5771051dB`) answers `TOKEN_JAR()` with its TokenJar in
about 400 gas.

On Monad the PoolManager has no `protocolFeeController` (checked at block 113,492,765), so the fee is 0 today; it applies from the block governance sets one. The hook does not report `protocolFeeFlags()`, so governance
classifies its pool through a pool override or its fee policy. A fill whose whole output would be the fee reverts
`ZeroAmount`.

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
and `10,000 - MAX_BID_BPS <= discountBps <= MAX_BID_DISCOUNT_BPS`.

`MAX_BID_DISCOUNT_BPS` is the swapper's protection: the bid can never sit more than that band below `sharePrice()`, so
it bounds the worst fill. A discount change inside the band takes effect at once, so a maker can still reprice a
pending swap whose slippage limit is tighter than the band down to that limit. The constructor
refuses an empty band (`10,000 - MAX_BID_BPS > MAX_BID_DISCOUNT_BPS`) and a band of 10,000 or more.

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
2. The hook runs `sync(USDC)`, `VAULT.withdraw(bid + fee, PoolManager, MAKER)` and `settle()`, then `take`s the fee
   to the TokenJar. MetaMorpho pulls the USDC from its withdraw queue; if its markets lack the liquidity, the whole
   swap reverts and nothing moves.
3. `sweep()` is permissionless and moves everything the hook holds to `MAKER`: its aHYPER and USDC claims and any
   aHYPER or USDC sent to it directly. `sweep(currency)` does the same for one currency, so a currency that cannot move
   (aHYPER while the strategy is paused) never strands the other.

## Safety properties

- No owner, not upgradeable; every address is immutable.
- Value only moves to `MAKER` (swept claims), from the maker's vault position to the PoolManager for the fill, or from
  that fill to the protocol fee's TokenJar.
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

- `Filled(sender, sharesIn, assetsOut, protocolFee, sharePrice)`: `assetsOut` is what the swapper received; the
  maker's cost is `assetsOut + protocolFee`.
- Keep `discountBps` inside `[10,000 - MAX_BID_BPS, MAX_BID_DISCOUNT_BPS]`; an opening outside it reverts.

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

Monad mainnet fork at block 113,335,000; 46 tests in the hook suite:

- fills through the mainnet UniversalRouter with Permit2 and empty `hookData`, exact-in and exact-out, at the discount
  and at the ceiling, with expected amounts computed independently from the formulas above;
- the price follows `sharePrice()` over time;
- direction, expiry, `remaining`, kill switch, every non-ongoing loan state, zero price, dust, parameter bounds on both
  sides of the band, access control, wrong pool (at initialise and at swap), constructor config; a killed bid reverts
  before calling the strategy;
- the protocol fee, installed through a fee adapter the way governance would: exact-in and exact-out amounts computed
  independently, only the sell direction's half charged, the fee reaching the TokenJar and nothing accruing in the
  PoolManager, no charge without a resolvable TokenJar (no code, a reverting call, a revert carrying 32 bytes, a zero
  address), a hostile controller under a 1,000,000-gas swap budget (1 MiB revert, gas burn, a non-address word, 1 MiB
  return, a 31-byte return) never blocking a fill, a dust fill that would be all fee reverting, and V4Quoter parity
  under the fee;
- a real strategy pause, and a real switch-off of aHYPER transfers, each stop a sale paid from PoolManager-held
  aHYPER and refuse to open a bid, while the kill switch and `sweep(USDC)` still work; a stale `expectedRemaining` makes a re-post revert;
- the fill-level ceiling holds even with a discount written straight into storage;
- a same-transaction redeem request (deposits are capped at the block) leaves the fill unchanged;
- funding bounded by the share allowance and by the maker's position; with the vault lending into a borrowed market, a
  fill up to the market's free liquidity succeeds and one base unit more reverts as a whole;
- sweep of claims and stray tokens, liquidity added and never traded, V4Quoter parity, a pool front-run-initialised at
  the minimum and maximum price.

Each guard in the hook was removed or altered one at a time (32 mutants, then 26 on the protocol fee and band, then 4
on the bounded `TOKEN_JAR()` call); every
mutant fails at least one test except two equivalent ones (the exact-out zero-amount guard, which the PoolManager
reaches first, and a rewrite of the withdrawal that leaves the amounts unchanged).

## Uniswap hook allowlist

How the hook stands against the criteria Uniswap's hook allowlist review applies to custom-accounting hooks:

| Criterion | This hook |
|---|---|
| Does not modify or bypass the AMM protocol fee | charges the pool's protocol fee on every fill and pays it to the TokenJar (above) |
| Allows minimal liquidity | `beforeAddLiquidity` is not set; anyone can add liquidity (it is never traded) |
| Maker cannot reprice a swap down to the swapper's slippage | partly: the immutable `MAX_BID_DISCOUNT_BPS` band bounds every fill at sharePrice x (1 - 3%); a discount change inside the band takes effect at once, so a swap with a slippage limit tighter than the band can still be repriced down to that limit |
| Source verified, not upgradeable, no owner | every address and bound is immutable; verify the source on the Monad explorer at deploy |
| Works with standard routing | empty `hookData`; fork-tested through the mainnet UniversalRouter and V4Quoter |

## Constructor

`(poolManager, vault, share, maker, maxBidBps, maxBidDiscountBps)`. The deployment the bot expects is
`(PoolManager, Apex, aHYPER, maker wallet, 9990, 300)`: discounts from 10 to 300 bps.

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
