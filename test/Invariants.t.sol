// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockIMD, BuyRouter} from "./utils/Mocks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PleaHook} from "../src/PleaHook.sol";

/// @dev Drives the launch with bounded inputs from three traders: buys, Cabal-approved sells, dumps
/// after the dead-man switch, settlements, rebalances, wall funding, fee withdrawals and time.
/// Every call either succeeds or the run fails (fail-on-revert); nothing is swallowed except the
/// hook's own RebalanceNotNeeded, which is the documented "nothing to do" answer.
contract PleaHandler is Test {
    string constant TEXT = "Dear Cabal, the invariant handler asks to sell a bounded share.";

    PoolManager pm;
    MockIMD imd;
    PLEA plea;
    CabalGate gate;
    PleaHook hook;
    BuyRouter router;
    address owner;
    uint256 signerKey;

    address[] public actors;
    uint256 nonce;

    // ghosts
    uint256 public lastSupply;
    uint256 public lastCap;
    uint128 public lastMarketLiquidity;
    bool public sawDead;
    uint256 public gateFeesIn;
    uint256 public gateWithdrawn;
    uint256 public buys;
    uint256 public partialBuys;
    uint256 public refundsAsClaims;
    uint256 public refundsAsErc20;
    uint256 public refusedNoRecipient;
    uint256 public plainBuysAfterDeath;
    uint256 public gatedSells;
    uint256 public emptySells;
    uint256 public dumps;
    uint256 public trims;
    uint256 public walls;
    uint256 public kills;

    constructor(
        PoolManager pm_,
        MockIMD imd_,
        PLEA plea_,
        CabalGate gate_,
        PleaHook hook_,
        BuyRouter router_,
        address owner_,
        uint256 signerKey_,
        address[] memory actors_
    ) {
        pm = pm_;
        imd = imd_;
        plea = plea_;
        gate = gate_;
        hook = hook_;
        router = router_;
        owner = owner_;
        signerKey = signerKey_;
        actors = actors_;
        lastSupply = plea.totalSupply();
        lastCap = hook.inventoryCap();
        (,, lastMarketLiquidity) = hook.market();
        for (uint256 i; i < actors.length; ++i) {
            imd.mint(actors[i], 100_000e18);
            vm.startPrank(actors[i]);
            imd.approve(address(router), type(uint256).max);
            imd.approve(address(gate), type(uint256).max);
            plea.approve(address(gate), type(uint256).max);
            plea.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    modifier tracked() {
        uint256 capBefore = hook.inventoryCap();
        uint256 heldBefore = hook.pleaInMarket();
        _;
        // monotone ghosts: supply and cap only fall, market liquidity only shrinks, death is final
        uint256 s = plea.totalSupply();
        assertLe(s, lastSupply, "PLEA supply grew");
        lastSupply = s;
        uint256 c = hook.inventoryCap();
        assertLe(c, lastCap, "inventory cap rose");
        lastCap = c;
        (,, uint128 liq) = hook.market();
        assertLe(liq, lastMarketLiquidity, "market liquidity grew");
        if (liq < lastMarketLiquidity) trims++;
        lastMarketLiquidity = liq;
        if (plea.cabalDead()) sawDead = true;
        capBefore;
        heldBefore;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 seed, uint256 imdIn) external tracked {
        address a = _actor(seed);
        imdIn = bound(imdIn, 1e15, 500e18);
        if (imd.balanceOf(a) < imdIn) imd.mint(a, imdIn);
        vm.prank(a);
        router.buyExactIn(imdIn, abi.encode(a));
        buys++;
    }

    /// @dev A buy small enough (under ~350k PLEA) that, after a day, the cap ratchets down to what is
    /// held: the next sell then pushes the market above the cap and exercises the trim.
    function buySmall(uint256 seed, uint256 imdIn) external tracked {
        address a = _actor(seed);
        imdIn = bound(imdIn, 1e16, 2e18);
        vm.prank(a);
        router.buyExactIn(imdIn, abi.encode(a));
        buys++;
    }

    /// @dev An exact-input buy that stops at a price limit a bounded number of ticks from spot, so the
    /// pool fills only part of the input and the hook must refund the fee it took on the rest. Two
    /// independent books must agree: what the trader actually parted with (IMD out of the wallet, net
    /// of a refund paid as ERC-20 or as an ERC-6909 IMD claim) and what the hook booked as cost basis
    /// (fill plus fee on the fill). The buyer never leaves with a PLEA claim, whatever the fill.
    function buyPartial(uint256 seed, uint256 imdIn, uint256 ticks) external tracked {
        address a = _actor(seed);
        imdIn = bound(imdIn, 1e16, 2_000e18);
        ticks = bound(ticks, 1, 3_000);
        if (imd.balanceOf(a) < imdIn) imd.mint(a, imdIn);
        uint160 limit = _buyLimit(int24(int256(ticks)));
        if (limit == 0) return; // the price already sits at the extreme on the buy side
        uint256 imdId = uint256(uint160(address(imd)));
        uint256 walletBefore = imd.balanceOf(a);
        uint256 claimsBefore = pm.balanceOf(a, imdId);
        // IMD the PoolManager can pay a refund from at afterSwap time: its balance now, minus the
        // matured fee claims this very swap redeems first (they leave the PoolManager before the refund)
        uint256 payable_ = imd.balanceOf(address(pm));
        if (block.number > hook.lastClaimBlock()) {
            uint256 matured = hook.imdRetainClaims() + hook.imdOwnerClaims() + hook.imdCashbackClaims();
            payable_ = payable_ > matured ? payable_ - matured : 0;
        }
        (uint256 spentBefore, uint256 heldBefore) = hook.costBasis(a);
        vm.prank(a);
        uint256 out = router.buyExactInLimit(imdIn, abi.encode(a), limit);
        (uint256 spentAfter, uint256 heldAfter) = hook.costBasis(a);
        uint256 parted = walletBefore - imd.balanceOf(a);
        uint256 claimsGained = pm.balanceOf(a, imdId) - claimsBefore;
        assertEq(parted - claimsGained, spentAfter - spentBefore, "wallet - claims disagree with the cost basis");
        assertLe(spentAfter - spentBefore, imdIn, "a partial fill never costs more than the input");
        assertEq(heldAfter - heldBefore, out, "PLEA received differs from the basis");
        assertEq(pm.balanceOf(a, uint256(uint160(address(plea)))), 0, "buyer holds PLEA claims");
        if (claimsGained != 0) {
            // a claim refund is only ever used when the PoolManager could not pay in ERC-20
            assertLt(payable_, claimsGained, "claims minted although the PoolManager could pay");
            refundsAsClaims++;
        } else if (spentAfter - spentBefore < imdIn) {
            refundsAsErc20++;
        }
        partialBuys++;
        buys++;
    }

    /// @dev A buy with no recipient in hookData. While the Cabal lives it must be refused with
    /// RecipientRequired and cost nothing; once the Cabal is dead plain v4 accounting applies and the
    /// router delivers the PLEA to its payer, stranding nothing.
    function buyNoRecipient(uint256 seed, uint256 imdIn) external tracked {
        address a = _actor(seed);
        imdIn = bound(imdIn, 1e16, 200e18);
        if (imd.balanceOf(a) < imdIn) imd.mint(a, imdIn);
        uint256 walletBefore = imd.balanceOf(a);
        uint256 pleaBefore = plea.balanceOf(a);
        bool alive = !plea.cabalDead();
        vm.prank(a);
        try router.buyExactIn(imdIn, "") returns (uint256 out) {
            assertFalse(alive, "a recipient-less buy went through while the Cabal lives");
            assertEq(plea.balanceOf(a) - pleaBefore, out);
            assertEq(plea.balanceOf(address(router)), 0, "PLEA stranded in the router");
            assertEq(pm.balanceOf(a, uint256(uint160(address(plea)))), 0);
            assertEq(pm.balanceOf(address(router), uint256(uint160(address(plea)))), 0, "router holds PLEA claims");
            plainBuysAfterDeath++;
            buys++;
        } catch (bytes memory err) {
            assertTrue(alive, "a plain router buy failed after killCabal");
            assertTrue(_mentions(err, PleaHook.RecipientRequired.selector), "refused for another reason");
            assertEq(imd.balanceOf(a), walletBefore, "a refused buy cost IMD");
            assertEq(plea.balanceOf(a), pleaBefore);
            refusedNoRecipient++;
        }
    }

    /// @dev The sqrt price `ticks` away from spot on the buy side, or 0 when no such limit is strictly
    /// beyond the current price (the price sits at the extreme after a dump exhausted the IMD side).
    function _buyLimit(int24 ticks) internal view returns (uint160) {
        int24 spot = hook.currentTick();
        uint160 cur = hook.currentSqrtPriceX96();
        if (hook.pleaIsZero()) {
            int24 t = spot + ticks;
            if (t > TickMath.MAX_TICK - 1) t = TickMath.MAX_TICK - 1;
            uint160 l = TickMath.getSqrtPriceAtTick(t);
            if (l >= TickMath.MAX_SQRT_PRICE) l = TickMath.MAX_SQRT_PRICE - 1;
            return l > cur ? l : 0;
        }
        int24 t = spot - ticks;
        if (t < TickMath.MIN_TICK + 1) t = TickMath.MIN_TICK + 1;
        uint160 l = TickMath.getSqrtPriceAtTick(t);
        if (l <= TickMath.MIN_SQRT_PRICE) l = TickMath.MIN_SQRT_PRICE + 1;
        return l < cur ? l : 0;
    }

    /// @dev Whether a (possibly v4-wrapped) revert payload carries the given selector anywhere.
    function _mentions(bytes memory err, bytes4 sel) internal pure returns (bool) {
        if (err.length < 4) return false;
        for (uint256 i; i + 4 <= err.length; ++i) {
            if (err[i] == sel[0] && err[i + 1] == sel[1] && err[i + 2] == sel[2] && err[i + 3] == sel[3]) return true;
        }
        return false;
    }

    /// @dev Plead, get approved by the test Cabal, execute. If the Cabal is dead, dump through the router.
    function sell(uint256 seed, uint256 shareBps) external tracked {
        address a = _actor(seed);
        uint256 bal = plea.balanceOf(a);
        if (bal < 100) return;
        if (plea.cabalDead()) {
            uint256 amt = bound(shareBps, 1, bal);
            vm.prank(a);
            router.sellExactIn(amt, abi.encode(a));
            dumps++;
            return;
        }
        uint256 max = bal * gate.MAX_SHARE_BPS() / 10_000;
        if (max > gate.MAX_SELL()) max = gate.MAX_SELL();
        if (max == 0) return;
        uint256 amount = bound(shareBps, 1, max);
        if (gate.pendingOf(a) != 0) return;
        uint256 until = gate.lastExecutedAt(a) + gate.COOLDOWN();
        if (gate.lastExecutedAt(a) != 0 && block.timestamp < until) _warpTo(until);
        vm.prank(a);
        uint256 id = gate.submitSell(amount, TEXT);
        gateFeesIn += gate.ORACLE_FEE();
        _deliver(id, true);
        vm.prank(a);
        uint256 out = gate.executeSell(0);
        if (out == 0) emptySells++;
        else gatedSells++;
    }

    function settle() external tracked {
        hook.settleClaims();
    }

    function rebalance() external tracked {
        try hook.rebalance() {
            (,, uint128 liq) = hook.wall();
            if (liq != 0) walls++;
        } catch (bytes memory err) {
            require(bytes4(err) == PleaHook.RebalanceNotNeeded.selector, "rebalance reverted for another reason");
        }
    }

    function fundWall(uint256 amount) external tracked {
        amount = bound(amount, 1, 50e18);
        imd.mint(address(this), amount);
        imd.approve(address(hook), amount);
        hook.fundWall(amount);
    }

    function withdrawFees(uint256 amount) external tracked {
        uint256 bal = imd.balanceOf(address(gate));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(owner);
        gate.withdrawImd(owner, amount);
        gateWithdrawn += amount;
    }

    function warp(uint256 secs) external tracked {
        secs = bound(secs, 1, 2 days);
        _warpTo(block.timestamp + secs);
    }

    function kill() external tracked {
        if (block.timestamp < gate.lastVerdictAt() + gate.DEADMAN()) return;
        gate.killCabal();
        kills++;
    }

    function _warpTo(uint256 t) internal {
        uint256 dt = t - block.timestamp;
        vm.warp(t);
        vm.roll(block.number + dt / 12 + 1);
    }

    function _deliver(uint256 id, bool answer) internal {
        uint64 toBlock = uint64(block.number);
        uint64 fromBlock = toBlock > 300 ? toBlock - 300 : 0;
        bytes32 requestId = keccak256(abi.encode("inv-req", id, nonce++));
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: requestId,
            chainId: 1,
            questionHash: gate.questionHash(id, fromBlock, toBlock),
            answerType: OracleAttestation.ANSWER_BOOL,
            answer: abi.encode(answer),
            figure: 0,
            fromBlock: fromBlock,
            toBlock: toBlock,
            blockHash: keccak256("block"),
            panelJobId: keccak256(abi.encode("job", requestId)),
            panelSize: 30,
            quorum: 20,
            agreed: 24,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 3600)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, gate.attestationDigest(a));
        gate.deliverVerdict(id, a, abi.encodePacked(r, s, v));
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract PleaInvariantTest is Fixture {
    PleaHandler handler;
    uint128 seedLiquidity;

    function setUp() public virtual override {
        super.setUp();
        skip(91 minutes); // past the launch window: no 5M-PLEA buy cap, no extra fee
        vm.roll(vm.getBlockNumber() + 450);
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = makeAddr("carol");
        handler = new PleaHandler(pm, imd, plea, gate, hook, router, OWNER, SIGNER_KEY, actors);
        (,, seedLiquidity) = hook.market();
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- supply

    /// @notice 1e9 minted once; afterwards the supply only burns down.
    function invariant_supplyOnlyBurnsDown() public view {
        assertLe(plea.totalSupply(), 1_000_000_000e18);
        assertLe(plea.totalSupply(), handler.lastSupply());
    }

    /// @notice Every PLEA is somewhere we can name: the pool, the distributor, or a trader.
    function invariant_supplyConserved() public view {
        uint256 sum = plea.balanceOf(address(pm)) + plea.balanceOf(address(distributor));
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += plea.balanceOf(handler.actors(i));
        }
        sum += plea.balanceOf(address(hook)) + plea.balanceOf(address(gate)) + plea.balanceOf(address(router));
        assertEq(sum, plea.totalSupply(), "PLEA leaked to an unnamed holder");
    }

    /// @notice The hook and the gate never keep PLEA of their own: everything is in the pool or burned.
    function invariant_hookAndGateHoldNoPlea() public view {
        assertEq(plea.balanceOf(address(hook)), 0, "hook holds PLEA outside the pool");
        assertEq(plea.balanceOf(address(gate)), 0, "gate kept a seller's PLEA");
    }

    // ---------------------------------------------------------------- IMD custody

    /// @notice The hook's real IMD equals the wall reserve plus the cashback float it says it owes.
    function invariant_hookImdBacksItsBooks() public view {
        assertEq(imd.balanceOf(address(hook)), hook.retainedImd() + hook.cashbackFloat(), "hook IMD != books");
    }

    /// @notice The PoolManager holds at least what the hook's bands and unsettled claims say it holds,
    /// plus every IMD claim a partial-fill refund minted to a trader.
    function invariant_poolBacksBandsAndClaims() public view {
        uint256 pleaOwed = hook.pleaInMarket() + hook.pleaInWall() + hook.pleaBurnClaims();
        assertGe(plea.balanceOf(address(pm)), pleaOwed, "pool short of PLEA");
        uint256 imdOwed = hook.imdInMarket() + _imdInWall() + hook.imdRetainClaims() + hook.imdOwnerClaims()
            + hook.imdCashbackClaims();
        uint256 imdId = uint256(uint160(address(imd)));
        for (uint256 i; i < handler.actorCount(); ++i) {
            imdOwed += pm.balanceOf(handler.actors(i), imdId);
        }
        assertGe(imd.balanceOf(address(pm)), imdOwed, "pool short of IMD");
    }

    /// @notice No trader and no router ever holds an ERC-6909 PLEA claim: that is the only way PLEA
    /// could reach a hookless pool while the Cabal lives, and after its death nothing mints them either.
    function invariant_noPleaClaimsOutsideHook() public view {
        uint256 pleaId = uint256(uint160(address(plea)));
        for (uint256 i; i < handler.actorCount(); ++i) {
            assertEq(pm.balanceOf(handler.actors(i), pleaId), 0, "a trader holds PLEA claims");
        }
        assertEq(pm.balanceOf(address(router), pleaId), 0, "the router holds PLEA claims");
        assertEq(pm.balanceOf(address(gate), pleaId), 0, "the gate holds PLEA claims");
        assertEq(pm.balanceOf(address(handler), pleaId), 0);
    }

    /// @notice A router is a pass-through: whichever accounting the hook used, it ends every call empty.
    function invariant_routerStrandsNothing() public view {
        assertEq(plea.balanceOf(address(router)), 0, "PLEA stranded in the router");
        assertEq(imd.balanceOf(address(router)), 0, "IMD stranded in the router");
    }

    /// @notice The gate's IMD is exactly the oracle fees it took minus what the owner withdrew.
    function invariant_gateImdIsFeesMinusWithdrawals() public view {
        assertEq(imd.balanceOf(address(gate)), handler.gateFeesIn() - handler.gateWithdrawn());
    }

    // ---------------------------------------------------------------- cap and liquidity

    /// @notice After every call the market holds no more than the cap plus the trim threshold, the cap
    /// never falls under the floor and never rises, and the locked seed liquidity only shrinks.
    function invariant_capAndLockedLiquidity() public view {
        assertLe(hook.pleaInMarket(), hook.inventoryCap() + hook.MIN_TRIM(), "PLEA above the cap left untrimmed");
        assertGe(hook.inventoryCap(), hook.CAP_FLOOR());
        assertLe(hook.inventoryCap(), handler.lastCap());
        (,, uint128 liq) = hook.market();
        assertLe(liq, seedLiquidity, "liquidity added to the market band");
        assertEq(hook.pendingTrim(), 0, "a trim is pending after a trade");
    }

    /// @notice The wall never holds IMD and PLEA from nowhere: it was funded from the reserve.
    function invariant_wallIsFundedFromReserve() public view {
        (,, uint128 liq) = hook.wall();
        if (liq == 0) {
            assertEq(hook.wallImd(), 0);
        } else {
            assertLe(_imdInWall(), hook.wallImd() + 1, "wall holds more IMD than it was deployed with");
        }
    }

    // ---------------------------------------------------------------- Cabal

    /// @notice Death is final and, while alive, no actor ever ends a call with a pending plea.
    function invariant_deathIsFinalAndNoDanglingPleas() public view {
        if (handler.sawDead()) assertTrue(plea.cabalDead(), "the Cabal came back");
        if (plea.cabalDead()) assertGt(plea.cabalKilledAt(), 0);
        for (uint256 i; i < handler.actorCount(); ++i) {
            assertEq(gate.pendingOf(handler.actors(i)), 0);
        }
    }

    function invariant_callSummary() public view {
        // nothing to assert: the counters are the handler's evidence of what the sequences covered
        handler.buys();
    }

    function _imdInWall() internal view returns (uint256) {
        (int24 lower, int24 upper, uint128 liq) = hook.wall();
        if (liq == 0) return 0;
        uint160 sqrtP = hook.currentSqrtPriceX96();
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        if (hook.pleaIsZero()) {
            if (sqrtP <= lo) return 0;
            if (sqrtP > hi) sqrtP = hi;
            return SqrtPriceMath.getAmount1Delta(lo, sqrtP, liq, false);
        }
        if (sqrtP >= hi) return 0;
        if (sqrtP < lo) sqrtP = lo;
        return SqrtPriceMath.getAmount0Delta(sqrtP, hi, liq, false);
    }
}

/// @dev The same sequences with PLEA as currency0.
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract PleaInvariantPleaIsZeroTest is PleaInvariantTest {
    function deployImd() internal override {
        deployCodeTo("Mocks.sol:MockIMD", "", address(type(uint160).max));
        imd = MockIMD(address(type(uint160).max));
    }

    function invariant_orientation() public view {
        assertTrue(hook.pleaIsZero());
    }
}
