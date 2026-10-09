// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*
  PleaHook — a fork of POOL4's CappedBurnHook (Ethereum 0xc6c965bd164c483e87d0b550671798e9a3602840),
  converted to the IMD side: the quote asset is TestIMD (an ERC-20) instead of ETH, the pool is
  PLEA/IMD with LP fee 0, the hook is the only LP, liquidity is locked forever (no closeMarket, no
  withdraw), trims burn 100% and recovered IMD becomes an IMD-only buy wall below the price.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IStacker} from "./interfaces/IStacker.sol";

interface IPLEAForHook {
    function cabalDead() external view returns (bool);
    function gate() external view returns (address);
    function burn(uint256 amount) external;
}

contract PleaHook {
    using StateLibrary for IPoolManager;

    error NotPlea();
    error NotPoolManager();
    error InvalidPool();
    error AlreadySeeded();
    error NotSeeded();
    error InitializationRestrictedToHook();
    error LiquidityRestrictedToHook();
    error SellsOnlyViaGate();
    error BuyTooLarge(uint256 amount, uint256 maximum);
    error CallbackNotExpected();
    error NotSelf();
    error RebalanceNotNeeded();
    error UnexpectedLiquidityDelta();
    error PriceMoved();
    error InvalidLiquidity();

    event Seeded(uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint256 pleaDeposited);
    event SeedDeferred();
    event FeesTaken(address indexed trader, bool buy, uint256 imdBasis, uint256 imdFee, uint256 pleaFee);
    event CashbackStacked(address indexed trader, uint256 amount);
    event CashbackPaidPlain(address indexed trader, uint256 amount);
    event CashbackOwed(address indexed trader, uint256 amount);
    event CapRatcheted(uint256 previousCap, uint256 newCap);
    event Trimmed(uint128 liquidityRemoved, uint256 pleaBurned, uint256 imdRetained);
    event WallDeployed(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 imdDeployed);
    event WallSettled(uint128 liquidity, uint256 pleaBurned, uint256 imdReturned);
    event ClaimsSettled(uint256 pleaBurned, uint256 imdRetained, uint256 imdToOwner, uint256 imdToCashback);
    event KeeperTipPaid(address indexed keeper, uint256 amount);
    event PriceCheckpoint(uint64 hour, uint256 priceX96);

    uint256 public constant BPS = 10_000;
    uint256 public constant CASHBACK_BPS = 50; // 0.5% of the IMD fill, to the trader
    uint256 public constant OWNER_BPS = 50; // 0.5% to the owner
    uint256 public constant POOL_BPS = 25; // 0.25% to pool liquidity (the wall)
    uint256 public constant IMD_FEE_BPS = CASHBACK_BPS + OWNER_BPS + POOL_BPS;
    uint256 public constant PLEA_BURN_BPS = 25; // 0.25% of the PLEA leg burned every trade
    uint256 public constant LAUNCH_WINDOW = 90 minutes;
    uint256 public constant LAUNCH_EXTRA_BPS = 7_000; // 70% -> 0% linear, to pool liquidity
    uint256 public constant LAUNCH_MAX_BUY = 5_000_000e18;
    uint256 public constant MARKET_CAP_IMD = 5_700e18;
    uint256 public constant CAP_FLOOR = 900_000e18;
    uint256 public constant CAP_DECAY_PER_DAY = 300_000e18;
    uint256 public constant MIN_TRIM = 1e18;
    uint256 public constant WALL_THRESHOLD = 1e18; // retained IMD worth a rebalance
    uint256 public constant WALL_MIN_FILL = 1_000e18; // PLEA bought by the wall worth a settle
    uint256 public constant KEEPER_TIP = 1e16; // 0.01 IMD per useful rebalance/settle
    /// @notice Gas kept back from the Stacker credit so the fallback and the rest of the swap fit.
    uint256 public constant RESERVE = 250_000;
    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 60;

    uint8 private constant ACTION_SEED = 1;
    uint8 private constant ACTION_SETTLE = 2;
    uint8 private constant ACTION_REBALANCE = 3;

    uint256 private constant T_TRADER = 0x01;
    uint256 private constant T_SPEC_FEE = 0x02;
    uint256 private constant T_BUY = 0x03;

    IPoolManager public immutable poolManager;
    address public immutable plea;
    IERC20 public immutable imd;
    IStacker public immutable stacker;
    address public immutable owner;
    bool public immutable pleaIsZero;
    int24 public immutable minTick;
    int24 public immutable maxTick;

    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Basis {
        uint256 imdSpent;
        uint256 pleaHeld;
    }

    struct Checkpoint {
        uint64 hour;
        uint256 priceX96;
    }

    bool public seeded;
    bool public seedDeferred;
    uint256 public launchedAt;
    Band public market;
    Band public wall;
    uint256 public inventoryCap;
    uint256 public lastCapDecayAt;
    uint256 public capDecayRemainder;
    uint256 public retainedImd;
    uint256 public cashbackFloat;
    uint256 public totalBurned;
    uint256 public totalOwnerFees;
    uint256 public totalCashback;
    uint256 public totalPoolFees;
    int24 public refTick;
    int24 private curBlockTick;
    uint64 private refBlock;
    int24 private constant MAX_REF_STEP = 200;

    uint256 public pleaBurnClaims;
    uint256 public imdRetainClaims;
    uint256 public imdOwnerClaims;
    uint256 public imdCashbackClaims;
    uint256 public lastClaimBlock;
    bool private callbackExpected;

    mapping(address => Basis) public basisOf;
    mapping(address => uint256) public cashbackOwed;
    Checkpoint[25] public ring;

    constructor(IPoolManager poolManager_, address plea_, IERC20 imd_, IStacker stacker_, address owner_) {
        poolManager = poolManager_;
        plea = plea_;
        imd = imd_;
        stacker = stacker_;
        owner = owner_;
        pleaIsZero = plea_ < address(imd_);
        minTick = TickMath.minUsableTick(TICK_SPACING);
        maxTick = TickMath.maxUsableTick(TICK_SPACING);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ------------------------------------------------------------------ views

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The flag bits a PleaHook address must carry in its low 14 bits.
    function requiredFlags() public pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    function poolKey() public view returns (PoolKey memory key) {
        (Currency c0, Currency c1) = pleaIsZero
            ? (Currency.wrap(plea), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(plea));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(this))
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    function currentSqrtPriceX96() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId());
    }

    function currentTick() public view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId());
    }

    /// @notice IMD per PLEA, scaled by 2^96.
    function priceX96() public view returns (uint256) {
        return _priceX96(currentSqrtPriceX96());
    }

    function _priceX96(uint160 sqrtP) internal view returns (uint256) {
        if (sqrtP == 0) return 0;
        uint256 p = FullMath.mulDiv(sqrtP, sqrtP, FixedPoint96.Q96); // token1 per token0, X96
        if (pleaIsZero) return p;
        if (p == 0) return 0;
        return FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, p);
    }

    /// @notice The checkpointed price from at least 24 hours ago (0 when none is old enough).
    function price24hAgo() public view returns (uint256) {
        uint64 target = uint64(block.timestamp / 1 hours) - 24;
        uint64 bestHour;
        uint256 best;
        for (uint256 i; i < 25; ++i) {
            Checkpoint memory c = ring[i];
            if (c.priceX96 != 0 && c.hour <= target && c.hour >= bestHour) {
                bestHour = c.hour;
                best = c.priceX96;
            }
        }
        return best;
    }

    function costBasis(address trader) external view returns (uint256 imdSpent, uint256 pleaHeld) {
        Basis memory b = basisOf[trader];
        return (b.imdSpent, b.pleaHeld);
    }

    /// @notice Extra buy fee in bps during the launch window: 70% at seed, 0% after 90 minutes.
    function launchExtraBps() public view returns (uint256) {
        if (launchedAt == 0) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= LAUNCH_WINDOW) return 0;
        return LAUNCH_EXTRA_BPS * (LAUNCH_WINDOW - elapsed) / LAUNCH_WINDOW;
    }

    function pleaInMarket() public view returns (uint256) {
        return _pleaIn(market, currentSqrtPriceX96());
    }

    function imdInMarket() public view returns (uint256) {
        return _imdIn(market, currentSqrtPriceX96());
    }

    function pleaInWall() public view returns (uint256) {
        return _pleaIn(wall, currentSqrtPriceX96());
    }

    function pendingTrim() public view returns (uint256) {
        uint256 held = pleaInMarket();
        uint256 excess = held > inventoryCap ? held - inventoryCap : 0;
        return excess < MIN_TRIM ? 0 : excess;
    }

    function pendingRebalance() public view returns (bool) {
        if (!seeded) return false;
        return retainedImd >= WALL_THRESHOLD || pleaInWall() >= WALL_MIN_FILL;
    }

    function _pleaIn(Band memory b, uint160 sqrtP) internal view returns (uint256) {
        if (b.liquidity == 0) return 0;
        uint160 lo = TickMath.getSqrtPriceAtTick(b.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(b.tickUpper);
        if (pleaIsZero) {
            if (sqrtP >= hi) return 0;
            if (sqrtP < lo) sqrtP = lo;
            return SqrtPriceMath.getAmount0Delta(sqrtP, hi, b.liquidity, false);
        }
        if (sqrtP <= lo) return 0;
        if (sqrtP > hi) sqrtP = hi;
        return SqrtPriceMath.getAmount1Delta(lo, sqrtP, b.liquidity, false);
    }

    function _imdIn(Band memory b, uint160 sqrtP) internal view returns (uint256) {
        if (b.liquidity == 0) return 0;
        uint160 lo = TickMath.getSqrtPriceAtTick(b.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(b.tickUpper);
        if (pleaIsZero) {
            if (sqrtP <= lo) return 0;
            if (sqrtP > hi) sqrtP = hi;
            return SqrtPriceMath.getAmount1Delta(lo, sqrtP, b.liquidity, false);
        }
        if (sqrtP >= hi) return 0;
        if (sqrtP < lo) sqrtP = lo;
        return SqrtPriceMath.getAmount0Delta(sqrtP, hi, b.liquidity, false);
    }

    // ------------------------------------------------------------------ seed

    /// @notice Creates the PLEA/IMD pool at a 5,700 IMD market cap with the hook's whole PLEA
    /// balance as the only liquidity. Called by PLEA.init in the deploy transaction. If the
    /// PoolManager has no code (the launch's empty-chain rehearsal) seeding is deferred and the
    /// owner may call it once the chain is real.
    function seed() external {
        if (seeded) revert AlreadySeeded();
        if (msg.sender != plea && !(seedDeferred && msg.sender == owner)) revert NotPlea();
        if (address(poolManager).code.length == 0) {
            seedDeferred = true;
            emit SeedDeferred();
            return;
        }
        seedDeferred = false;
        seeded = true;
        uint256 pleaAmount = IERC20(plea).balanceOf(address(this));
        // sqrt(IMD/PLEA ratio) in the pool's token1/token0 orientation.
        uint256 priceX192 = pleaIsZero
            ? FullMath.mulDiv(MARKET_CAP_IMD, 1 << 192, 1_000_000_000e18)
            : FullMath.mulDiv(1_000_000_000e18, 1 << 192, MARKET_CAP_IMD);
        uint160 sqrtP = uint160(_sqrt(priceX192));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower;
        int24 upper;
        uint160 initPrice;
        if (pleaIsZero) {
            lower = _alignUp(tick);
            upper = maxTick;
            initPrice = TickMath.getSqrtPriceAtTick(lower) - 1; // tick < lower: PLEA (token0) only
        } else {
            lower = minTick;
            upper = _alignDown(tick);
            initPrice = TickMath.getSqrtPriceAtTick(upper); // tick >= upper: PLEA (token1) only
        }
        uint128 liquidity = _liquidityForSingleSide(lower, upper, pleaAmount, pleaIsZero);
        int24 initTick = poolManager.initialize(poolKey(), initPrice);
        market = Band({tickLower: lower, tickUpper: upper, liquidity: liquidity});
        bytes memory res = _unlock(abi.encode(ACTION_SEED, abi.encode(lower, upper, liquidity)));
        uint256 deposited = abi.decode(res, (uint256));
        inventoryCap = deposited;
        lastCapDecayAt = block.timestamp;
        launchedAt = block.timestamp;
        refTick = initTick;
        curBlockTick = initTick;
        refBlock = uint64(block.number);
        // Any PLEA dust the rounding left behind is burned: the hook holds no inventory of its own.
        uint256 dust = IERC20(plea).balanceOf(address(this));
        if (dust != 0) IPLEAForHook(plea).burn(dust);
        _approveStacker();
        _checkpoint(initPrice);
        emit Seeded(initPrice, initTick, liquidity, deposited);
    }

    function _approveStacker() internal {
        if (address(stacker).code.length == 0) return;
        try imd.approve(address(stacker), type(uint256).max) {} catch {}
    }

    // ------------------------------------------------------------------ hooks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        _requirePoolManagerAndPool(key);
        if (sender != address(this)) revert InitializationRestrictedToHook();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _requirePoolManagerAndPool(key);
        if (sender != address(this)) revert LiquidityRestrictedToHook();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Gates sells and takes the fee on the specified currency.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePoolManagerAndPool(key);
        if (!seeded) revert NotSeeded();
        bool buy = params.zeroForOne != pleaIsZero;
        if (!buy && !IPLEAForHook(plea).cabalDead() && sender != IPLEAForHook(plea).gate()) revert SellsOnlyViaGate();
        address trader = hookData.length == 32 ? abi.decode(hookData, (address)) : sender;
        bool exactIn = params.amountSpecified < 0;
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        bool specifiedIsImd = buy == exactIn;
        uint256 fee;
        if (specifiedIsImd) {
            fee = amount * (IMD_FEE_BPS + (buy ? launchExtraBps() : 0)) / BPS;
        } else {
            if (buy) _checkMaxBuy(amount);
            fee = amount * PLEA_BURN_BPS / BPS;
        }
        assembly ("memory-safe") {
            tstore(T_TRADER, trader)
            tstore(T_SPEC_FEE, fee)
            tstore(T_BUY, buy)
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// @notice Takes the fee on the unspecified currency, books everything, applies the cap, then
    /// pays cashback as the very last step.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _requirePoolManagerAndPool(key);
        address trader;
        uint256 specFee;
        bool buy;
        assembly ("memory-safe") {
            trader := tload(T_TRADER)
            specFee := tload(T_SPEC_FEE)
            buy := tload(T_BUY)
            tstore(T_TRADER, 0)
            tstore(T_SPEC_FEE, 0)
            tstore(T_BUY, 0)
        }
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsZero = exactIn == params.zeroForOne;
        uint256 specAmt = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        int128 u = specifiedIsZero ? delta.amount1() : delta.amount0();
        uint256 unspecAmt = u < 0 ? uint256(uint128(-u)) : uint256(uint128(u));
        bool specifiedIsImd = buy == exactIn;

        uint256 imdBasis;
        uint256 imdFee;
        uint256 pleaFee;
        uint256 pleaAmt;
        uint256 unspecFee;
        if (specifiedIsImd) {
            imdBasis = specAmt;
            imdFee = specFee;
            if (buy) _checkMaxBuy(unspecAmt);
            pleaFee = unspecAmt * PLEA_BURN_BPS / BPS;
            pleaAmt = unspecAmt;
            unspecFee = pleaFee;
        } else {
            imdBasis = unspecAmt;
            imdFee = unspecAmt * (IMD_FEE_BPS + (buy ? launchExtraBps() : 0)) / BPS;
            pleaFee = specFee;
            pleaAmt = specAmt;
            unspecFee = imdFee;
        }
        _bookFees(imdBasis, imdFee, pleaFee);
        _updateBasis(trader, buy, imdBasis, imdFee, pleaAmt, pleaFee, specifiedIsImd, exactIn);
        emit FeesTaken(trader, buy, imdBasis, imdFee, pleaFee);

        _maybeRedeemMaturedClaims();
        _applyCap();
        _observeTick();
        _checkpoint(currentSqrtPriceX96());

        uint256 cashback = imdBasis * CASHBACK_BPS / BPS;
        _payCashback(trader, cashback);
        return (IHooks.afterSwap.selector, int128(int256(unspecFee)));
    }

    function _checkMaxBuy(uint256 pleaAmount) internal view {
        if (block.timestamp < launchedAt + LAUNCH_WINDOW && pleaAmount > LAUNCH_MAX_BUY) {
            revert BuyTooLarge(pleaAmount, LAUNCH_MAX_BUY);
        }
    }

    /// @dev Converts the fee deltas the hook holds into ERC-6909 claims, split by purpose.
    function _bookFees(uint256 imdBasis, uint256 imdFee, uint256 pleaFee) internal {
        if (pleaFee != 0) {
            poolManager.mint(address(this), _id(plea), pleaFee);
            pleaBurnClaims += pleaFee;
            totalBurned += pleaFee;
        }
        if (imdFee != 0) {
            poolManager.mint(address(this), _id(address(imd)), imdFee);
            uint256 cashback = imdBasis * CASHBACK_BPS / BPS;
            uint256 toOwner = imdBasis * OWNER_BPS / BPS;
            uint256 toPool = imdFee - cashback - toOwner;
            imdCashbackClaims += cashback;
            imdOwnerClaims += toOwner;
            imdRetainClaims += toPool;
            totalOwnerFees += toOwner;
            totalPoolFees += toPool;
        }
        if (pleaFee != 0 || imdFee != 0) lastClaimBlock = block.number;
    }

    function _updateBasis(
        address trader,
        bool buy,
        uint256 imdBasis,
        uint256 imdFee,
        uint256 pleaAmt,
        uint256 pleaFee,
        bool specifiedIsImd,
        bool exactIn
    ) internal {
        Basis storage b = basisOf[trader];
        if (buy) {
            // Gross IMD paid: the specified exact-in amount already includes the fee.
            uint256 gross = (specifiedIsImd && exactIn) ? imdBasis : imdBasis + imdFee;
            uint256 net = (!specifiedIsImd && !exactIn) ? pleaAmt : pleaAmt - pleaFee;
            b.imdSpent += gross;
            b.pleaHeld += net;
        } else {
            uint256 sold = (specifiedIsImd && !exactIn) ? pleaAmt + pleaFee : pleaAmt;
            if (sold >= b.pleaHeld) {
                b.imdSpent = 0;
                b.pleaHeld = 0;
            } else {
                b.imdSpent -= FullMath.mulDiv(b.imdSpent, sold, b.pleaHeld);
                b.pleaHeld -= sold;
            }
        }
    }

    // ------------------------------------------------------------------ cashback

    /// @dev Never reverts the trade. Pays from the real IMD float; if the float is short the amount
    /// is owed and claimable once `settleClaims` has refilled it.
    function _payCashback(address trader, uint256 amount) internal {
        if (amount == 0) return;
        if (cashbackFloat < amount) {
            cashbackOwed[trader] += amount;
            emit CashbackOwed(trader, amount);
            return;
        }
        cashbackFloat -= amount;
        _deliverCashback(trader, amount);
    }

    function _deliverCashback(address trader, uint256 amount) internal {
        totalCashback += amount;
        if (gasleft() > RESERVE) {
            try stacker.credit{gas: gasleft() - RESERVE}(trader, amount) {
                emit CashbackStacked(trader, amount);
                return;
            } catch {}
        }
        (bool ok, bytes memory ret) = address(imd).call(abi.encodeCall(IERC20.transfer, (trader, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) {
            emit CashbackPaidPlain(trader, amount);
        } else {
            totalCashback -= amount;
            cashbackFloat += amount;
            cashbackOwed[trader] += amount;
            emit CashbackOwed(trader, amount);
        }
    }

    /// @notice Pays cashback that could not be paid at trade time, once the float covers it.
    function claimCashback() external {
        uint256 owed = cashbackOwed[msg.sender];
        if (owed == 0 || cashbackFloat < owed) return;
        cashbackOwed[msg.sender] = 0;
        cashbackFloat -= owed;
        _deliverCashback(msg.sender, owed);
    }

    // ------------------------------------------------------------------ cap

    function _applyCap() internal {
        Band memory m = market;
        if (m.liquidity == 0) return;
        uint160 priceBefore = currentSqrtPriceX96();
        uint256 held = _pleaIn(m, priceBefore);
        if (held < inventoryCap) {
            uint256 next = held; // full ratchet
            uint256 elapsed = block.timestamp - lastCapDecayAt;
            uint256 allowance = CAP_DECAY_PER_DAY * elapsed / 1 days;
            uint256 rateFloor = inventoryCap > allowance ? inventoryCap - allowance : 0;
            if (next < rateFloor) next = rateFloor;
            if (next < CAP_FLOOR) next = CAP_FLOOR;
            if (next < inventoryCap) {
                uint256 used = inventoryCap - next;
                uint256 numerator = used * 1 days + capDecayRemainder;
                lastCapDecayAt += numerator / CAP_DECAY_PER_DAY;
                capDecayRemainder = numerator % CAP_DECAY_PER_DAY;
                emit CapRatcheted(inventoryCap, next);
                inventoryCap = next;
            }
            return;
        }
        uint256 excess = held - inventoryCap;
        if (excess < MIN_TRIM) return;
        uint256 toRemove = FullMath.mulDiv(m.liquidity, excess, held);
        if (toRemove == 0) return;
        (uint256 pleaOut, uint256 imdOut) = _removeLiquidity(m.tickLower, m.tickUpper, toRemove);
        market.liquidity = m.liquidity - uint128(toRemove);
        _claimTrim(pleaOut, imdOut);
        if (currentSqrtPriceX96() != priceBefore) revert PriceMoved();
        emit Trimmed(uint128(toRemove), pleaOut, imdOut);
    }

    function _claimTrim(uint256 pleaOut, uint256 imdOut) internal {
        if (pleaOut != 0) {
            poolManager.mint(address(this), _id(plea), pleaOut);
            pleaBurnClaims += pleaOut;
            totalBurned += pleaOut;
        }
        if (imdOut != 0) {
            poolManager.mint(address(this), _id(address(imd)), imdOut);
            imdRetainClaims += imdOut;
        }
        if (pleaOut != 0 || imdOut != 0) lastClaimBlock = block.number;
    }

    function _removeLiquidity(int24 lower, int24 upper, uint256 liquidity)
        internal
        returns (uint256 pleaOut, uint256 imdOut)
    {
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            poolKey(),
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -int256(liquidity), salt: 0}),
            ""
        );
        if (d.amount0() < 0 || d.amount1() < 0) revert UnexpectedLiquidityDelta();
        (uint256 a0, uint256 a1) = (uint256(uint128(d.amount0())), uint256(uint128(d.amount1())));
        (pleaOut, imdOut) = pleaIsZero ? (a0, a1) : (a1, a0);
    }

    // ------------------------------------------------------------------ wall

    /// @notice Permissionless: settles a filled wall (burning the PLEA it bought) and redeploys all
    /// retained IMD as one IMD-only band just below the price. Pays the caller a tip from retained IMD.
    function rebalance() external {
        if (!seeded) revert NotSeeded();
        _settleMaturedOrRevert();
        if (!pendingRebalance()) revert RebalanceNotNeeded();
        _unlock(abi.encode(ACTION_REBALANCE, ""));
        _payTip(msg.sender);
    }

    function _rebalance() internal {
        _closeWall();
        uint256 amount = retainedImd > KEEPER_TIP ? retainedImd - KEEPER_TIP : 0;
        if (amount == 0) return;
        int24 spot = currentTick();
        int24 lower;
        int24 upper;
        if (pleaIsZero) {
            // IMD is token1: the band sits below spot (tick >= upper). Use the safer of spot/refTick.
            int24 edge = spot < refTick ? spot : refTick;
            upper = _alignDown(edge);
            lower = minTick;
            if (upper <= lower) return;
        } else {
            // IMD is token0: the band sits above spot (tick < lower).
            int24 edge = spot > refTick ? spot : refTick;
            lower = _alignUp(edge + 1);
            upper = maxTick;
            if (lower >= upper) return;
        }
        uint128 liquidity = _liquidityForSingleSide(lower, upper, amount, !pleaIsZero);
        if (liquidity == 0) return;
        uint160 priceBefore = currentSqrtPriceX96();
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            poolKey(),
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
        if (d.amount0() > 0 || d.amount1() > 0) revert UnexpectedLiquidityDelta();
        (uint256 n0, uint256 n1) = (uint256(uint128(-d.amount0())), uint256(uint128(-d.amount1())));
        (uint256 pleaReq, uint256 imdReq) = pleaIsZero ? (n0, n1) : (n1, n0);
        if (pleaReq != 0) revert InvalidLiquidity();
        if (imdReq > amount) revert InvalidLiquidity();
        _settleImd(imdReq);
        retainedImd -= imdReq;
        wall = Band({tickLower: lower, tickUpper: upper, liquidity: liquidity});
        if (currentSqrtPriceX96() != priceBefore) revert PriceMoved();
        emit WallDeployed(lower, upper, liquidity, imdReq);
    }

    function _closeWall() internal {
        Band memory w = wall;
        if (w.liquidity == 0) return;
        (uint256 pleaOut, uint256 imdOut) = _removeLiquidity(w.tickLower, w.tickUpper, w.liquidity);
        delete wall;
        if (pleaOut != 0) {
            poolManager.take(Currency.wrap(plea), address(this), pleaOut);
            IPLEAForHook(plea).burn(pleaOut);
            totalBurned += pleaOut;
        }
        if (imdOut != 0) {
            poolManager.take(Currency.wrap(address(imd)), address(this), imdOut);
            retainedImd += imdOut;
        }
        emit WallSettled(w.liquidity, pleaOut, imdOut);
    }

    /// @notice Anyone may add IMD to the wall's reserve (the gate routes appeal fees here).
    function fundWall(uint256 amount) external {
        imd.transferFrom(msg.sender, address(this), amount);
        retainedImd += amount;
    }

    // ------------------------------------------------------------------ claims

    /// @notice Converts matured claims into real transfers: PLEA is burned, IMD goes to the owner,
    /// the cashback float and the wall reserve. Pays the caller a tip when there was work.
    function settleClaims() external {
        if (block.number <= lastClaimBlock) return;
        if (!_hasClaims()) return;
        _unlock(abi.encode(ACTION_SETTLE, ""));
        _payTip(msg.sender);
    }

    function redeemClaimsSelf() external {
        if (msg.sender != address(this)) revert NotSelf();
        _unlock(abi.encode(ACTION_SETTLE, ""));
    }

    function _maybeRedeemMaturedClaims() internal {
        if (block.number <= lastClaimBlock || !_hasClaims()) return;
        try this.redeemClaimsSelf() {} catch {}
    }

    function _settleMaturedOrRevert() internal {
        if (block.number > lastClaimBlock && _hasClaims()) _unlock(abi.encode(ACTION_SETTLE, ""));
    }

    function _hasClaims() internal view returns (bool) {
        return pleaBurnClaims != 0 || imdRetainClaims != 0 || imdOwnerClaims != 0 || imdCashbackClaims != 0;
    }

    function _redeem() internal {
        uint256 toBurn = pleaBurnClaims;
        uint256 toRetain = imdRetainClaims;
        uint256 toOwner = imdOwnerClaims;
        uint256 toCashback = imdCashbackClaims;
        pleaBurnClaims = 0;
        imdRetainClaims = 0;
        imdOwnerClaims = 0;
        imdCashbackClaims = 0;
        if (toBurn != 0) {
            poolManager.burn(address(this), _id(plea), toBurn);
            poolManager.take(Currency.wrap(plea), address(this), toBurn);
            IPLEAForHook(plea).burn(toBurn);
        }
        uint256 imdTotal = toRetain + toOwner + toCashback;
        if (imdTotal != 0) {
            poolManager.burn(address(this), _id(address(imd)), imdTotal);
            if (toOwner != 0) poolManager.take(Currency.wrap(address(imd)), owner, toOwner);
            if (toRetain + toCashback != 0) {
                poolManager.take(Currency.wrap(address(imd)), address(this), toRetain + toCashback);
            }
            retainedImd += toRetain;
            cashbackFloat += toCashback;
        }
        emit ClaimsSettled(toBurn, toRetain, toOwner, toCashback);
    }

    function _payTip(address keeper) internal {
        uint256 tip = KEEPER_TIP;
        if (retainedImd < tip) return;
        retainedImd -= tip;
        (bool ok,) = address(imd).call(abi.encodeCall(IERC20.transfer, (keeper, tip)));
        if (!ok) retainedImd += tip;
        else emit KeeperTipPaid(keeper, tip);
    }

    // ------------------------------------------------------------------ unlock plumbing

    function _unlock(bytes memory data) internal returns (bytes memory) {
        callbackExpected = true;
        return poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!callbackExpected) revert CallbackNotExpected();
        callbackExpected = false;
        (uint8 action, bytes memory payload) = abi.decode(raw, (uint8, bytes));
        if (action == ACTION_SEED) {
            (int24 lower, int24 upper, uint128 liquidity) = abi.decode(payload, (int24, int24, uint128));
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                poolKey(),
                ModifyLiquidityParams({
                    tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: 0
                }),
                ""
            );
            if (d.amount0() > 0 || d.amount1() > 0) revert UnexpectedLiquidityDelta();
            (uint256 n0, uint256 n1) = (uint256(uint128(-d.amount0())), uint256(uint128(-d.amount1())));
            (uint256 pleaReq, uint256 imdReq) = pleaIsZero ? (n0, n1) : (n1, n0);
            if (imdReq != 0) revert InvalidLiquidity();
            poolManager.sync(Currency.wrap(plea));
            IERC20(plea).transfer(address(poolManager), pleaReq);
            poolManager.settle();
            return abi.encode(pleaReq);
        }
        if (action == ACTION_SETTLE) {
            _redeem();
            return "";
        }
        if (action == ACTION_REBALANCE) {
            _rebalance();
            return "";
        }
        revert CallbackNotExpected();
    }

    function _settleImd(uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(Currency.wrap(address(imd)));
        imd.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    // ------------------------------------------------------------------ helpers

    function _observeTick() internal {
        if (block.number != refBlock) {
            int24 target = curBlockTick;
            int24 d = target - refTick;
            if (d > MAX_REF_STEP) target = refTick + MAX_REF_STEP;
            else if (d < -MAX_REF_STEP) target = refTick - MAX_REF_STEP;
            refTick = target;
            refBlock = uint64(block.number);
        }
        curBlockTick = currentTick();
    }

    function _checkpoint(uint160 sqrtP) internal {
        uint64 hour = uint64(block.timestamp / 1 hours);
        Checkpoint storage c = ring[hour % 25];
        if (c.hour != hour) {
            uint256 p = _priceX96(sqrtP);
            c.hour = hour;
            c.priceX96 = p;
            emit PriceCheckpoint(hour, p);
        }
    }

    /// @dev Liquidity for an amount of one side only. `isToken0` says which side the amount is.
    function _liquidityForSingleSide(int24 lower, int24 upper, uint256 amount, bool isToken0)
        internal
        pure
        returns (uint128)
    {
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        uint256 l;
        if (isToken0) {
            uint256 intermediate = FullMath.mulDiv(lo, hi, FixedPoint96.Q96);
            l = FullMath.mulDiv(amount, intermediate, hi - lo);
        } else {
            l = FullMath.mulDiv(amount, FixedPoint96.Q96, hi - lo);
        }
        l = l - l / 1_000_000; // rounding margin so the add never asks for more than `amount`
        if (l > type(uint128).max) revert InvalidLiquidity();
        return uint128(l);
    }

    function _alignUp(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (aligned < tick) aligned += TICK_SPACING;
        return aligned;
    }

    function _alignDown(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (aligned > tick) aligned -= TICK_SPACING;
        return aligned;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _id(address currency) internal pure returns (uint256) {
        return uint256(uint160(currency));
    }

    function _requirePoolManagerAndPool(PoolKey calldata key) internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId())) revert InvalidPool();
    }
}
