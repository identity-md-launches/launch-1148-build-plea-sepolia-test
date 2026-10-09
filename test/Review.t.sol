// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PleaHook} from "../src/PleaHook.sol";

/// @dev Buys on the hook pool and tries to keep the PLEA as ERC-6909 claims, then sells the claims
/// in a hookless PLEA/IMD pool. Neither step moves an ERC-20 PLEA token out of the trader.
contract ClaimsTrader {
    IPoolManager pm;
    PleaHook hook;
    IERC20 imd;
    address plea;

    constructor(IPoolManager pm_, PleaHook hook_, IERC20 imd_, address plea_) {
        pm = pm_;
        hook = hook_;
        imd = imd_;
        plea = plea_;
    }

    function buyAsClaims(uint256 imdIn) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(uint8(1), imdIn, hook.poolKey())), (uint256));
    }

    function sellClaimsHookless(uint256 pleaIn, PoolKey memory key) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(uint8(2), pleaIn, key)), (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (uint8 action, uint256 amount, PoolKey memory key) = abi.decode(raw, (uint8, uint256, PoolKey));
        bool pleaIsZero = Currency.unwrap(key.currency0) == plea;
        if (action == 1) {
            BalanceDelta d = pm.swap(
                key,
                SwapParams({
                    zeroForOne: !pleaIsZero,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: !pleaIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                abi.encode(address(this))
            );
            int128 pleaD = pleaIsZero ? d.amount0() : d.amount1();
            int128 imdD = pleaIsZero ? d.amount1() : d.amount0();
            pm.sync(Currency.wrap(address(imd)));
            imd.transfer(address(pm), uint256(uint128(-imdD)));
            pm.settle();
            if (pleaD > 0) pm.mint(address(this), uint256(uint160(plea)), uint256(uint128(pleaD)));
            return abi.encode(uint256(uint128(pleaD)));
        }
        BalanceDelta d2 = pm.swap(
            key,
            SwapParams({
                zeroForOne: pleaIsZero,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: pleaIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 pD = pleaIsZero ? d2.amount0() : d2.amount1();
        int128 iD = pleaIsZero ? d2.amount1() : d2.amount0();
        pm.burn(address(this), uint256(uint160(plea)), uint256(uint128(-pD)));
        pm.take(Currency.wrap(address(imd)), address(this), uint256(uint128(iD)));
        return abi.encode(uint256(uint128(iD)));
    }
}

contract HooklessLp {
    IPoolManager pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function add(PoolKey memory key, int24 lower, int24 upper, uint256 liq) external {
        pm.unlock(abi.encode(key, lower, upper, liq));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (PoolKey memory key, int24 lower, int24 upper, uint256 liq) = abi.decode(raw, (PoolKey, int24, int24, uint256));
        (BalanceDelta d,) = pm.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(liq), salt: 0}), ""
        );
        if (d.amount0() < 0) _pay(key.currency0, uint256(uint128(-d.amount0())));
        if (d.amount1() < 0) _pay(key.currency1, uint256(uint128(-d.amount1())));
        return "";
    }

    function _pay(Currency c, uint256 amount) internal {
        pm.sync(c);
        IERC20(Currency.unwrap(c)).transfer(address(pm), amount);
        pm.settle();
    }
}

/// @notice Regressions for the independent review's findings.
contract ReviewTest is Fixture {
    string constant TEXT = "Dear Cabal, I held through everything and need a little for rent.";

    function afterLaunchWindow() internal {
        skip(91 minutes);
        vm.roll(vm.getBlockNumber() + 450);
    }

    function _claim(address who, uint256 amount) internal {
        bytes32 leaf = keccak256(abi.encodePacked(uint256(0), who, amount));
        vm.prank(OWNER);
        distributor.setMerkleRoot(leaf);
        distributor.claim(0, who, amount, new bytes32[](0));
    }

    // ---------------------------------------------------------------- claims bypass (high)

    function test_buyerNeverLeavesWithPleaClaims() public {
        afterLaunchWindow();
        ClaimsTrader trader = new ClaimsTrader(IPoolManager(address(pm)), hook, imd, address(plea));
        imd.mint(address(trader), 100e18);
        uint256 claims = trader.buyAsClaims(100e18);
        // the swapper's PLEA delta is zero: the hook delivered the PLEA as ERC-20 to the trader
        assertEq(claims, 0, "no positive PLEA delta to mint claims from");
        assertEq(pm.balanceOf(address(trader), uint256(uint160(address(plea)))), 0);
        assertGt(plea.balanceOf(address(trader)), 0);
        // a hookless pool with IMD liquidity exists, but there is nothing to sell into it
        PoolKey memory key = hook.poolKey();
        key.hooks = IHooks(address(0));
        key.fee = 3000;
        int24 spot = hook.currentTick();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(spot));
        HooklessLp lp = new HooklessLp(IPoolManager(address(pm)));
        imd.mint(address(lp), 1_000e18);
        int24 s = (spot / 60) * 60;
        if (hook.pleaIsZero()) lp.add(key, s - 6000, s - 60, 1e22);
        else lp.add(key, s + 120, s + 6000, 1e22);
        vm.expectRevert(); // burning claims it does not hold
        trader.sellClaimsHookless(1e18, key);
        // and the ERC-20 PLEA it holds cannot reach the PoolManager either
        vm.prank(address(trader));
        vm.expectRevert();
        plea.transfer(address(pm), 1e18);
        assertFalse(plea.cabalDead());
        assertEq(gate.nextId(), 1);
    }

    function test_exactOutputBuyRefusedWhileAlive() public {
        afterLaunchWindow();
        vm.prank(alice);
        vm.expectRevert();
        router.buyExactOut(1_000e18, abi.encode(alice));
    }

    // ---------------------------------------------------------------- fees on the fill (medium)

    function test_sellThatFillsNothingPaysNoFee() public {
        afterLaunchWindow();
        _claim(alice, 100_000_000e18);
        skip(1 days);
        assertEq(hook.imdInMarket(), 0);
        vm.prank(alice);
        uint256 id = gate.submitSell(2_500_000e18, TEXT);
        deliver(id, true);
        uint256 before = plea.balanceOf(alice);
        vm.prank(alice);
        uint256 out = gate.executeSell(0);
        assertEq(out, 0);
        assertEq(plea.balanceOf(alice), before, "nothing sold, nothing charged");
        assertEq(hook.pleaBurnClaims(), 0);
        (, uint256 held) = hook.costBasis(alice);
        assertEq(held, 0); // distributor PLEA never had a basis; a zero sell leaves it alone
    }

    function test_partialSellChargesFeeOnFillOnly() public {
        afterLaunchWindow();
        uint256 bought = buy(bob, 10e18); // puts ~fill IMD in the market band
        _claim(alice, 100_000_000e18);
        skip(1 days);
        uint256 imdInPool = hook.imdInMarket();
        assertGt(imdInPool, 0);
        vm.prank(alice);
        uint256 id = gate.submitSell(2_500_000e18, TEXT); // far more than the pool can pay for
        deliver(id, true);
        uint256 before = plea.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = gate.executeSell(0);
        assertGt(out, 0);
        uint256 sold = before - plea.balanceOf(alice);
        assertLt(sold, 2_500_000e18, "partial fill");
        // FeesTaken(trader, buy, imdBasis, imdFee, pleaFee): the burn fee is 0.25% of what the pool
        // took, not of the 2.5M requested (which would be 6,250 PLEA)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burn = _pleaFeeFromLogs(logs);
        assertEq(burn, (sold - burn) * 25 / 10_000);
        assertLt(burn, 6_250e18);
        bought; // silence
    }

    function _pleaFeeFromLogs(Vm.Log[] memory logs) internal pure returns (uint256 pleaFee) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PleaHook.FeesTaken.selector) {
                (,,, pleaFee) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            }
        }
    }

    // ---------------------------------------------------------------- question binding (medium)

    function test_questionBindsPleaIdAndSeller() public {
        afterLaunchWindow();
        _claim(alice, 1_000_000e18);
        vm.prank(alice);
        plea.transfer(address(gate), 0); // no-op; alice already approved the gate in setUp
        bytes32 leaf = keccak256(abi.encodePacked(uint256(0), bob, uint256(1_000_000e18)));
        leaf; // bob gets PLEA through a buy instead
        buy(bob, 10e18);
        skip(2 days);
        vm.prank(alice);
        uint256 idA = gate.submitSell(100_000e18, TEXT);
        vm.prank(bob);
        uint256 idB = gate.submitSell(100_000e18, TEXT);
        assertTrue(keccak256(bytes(gate.question(idA))) != keccak256(bytes(gate.question(idB))));
        OracleAttestation.Attestation memory a = attestationFor(idA, true, keccak256("alice-request"));
        bytes memory sig = sign(a);
        vm.expectRevert(CabalGate.QuestionMismatch.selector);
        gate.deliverVerdict(idB, a, sig);
        gate.deliverVerdict(idA, a, sig);
        assertEq(uint8(gate.getPlea(idA).status), uint8(CabalGate.Status.Approved));
    }

    // ---------------------------------------------------------------- appeal cooldown (medium)

    function test_appealRespectsExecutedSellCooldown() public {
        afterLaunchWindow();
        buy(alice, 10e18);
        nextBlock();
        vm.prank(alice);
        uint256 id1 = gate.submitSell(1e18, TEXT);
        deliver(id1, false);
        skip(4 hours);
        vm.prank(alice);
        uint256 id2 = gate.submitSell(1e18, TEXT);
        deliver(id2, true);
        vm.prank(alice);
        gate.executeSell(0);
        skip(1 minutes);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, block.timestamp - 1 minutes + 4 hours));
        gate.appeal(id1, "Please reconsider my first plea, kind Cabal.");
        skip(4 hours);
        vm.prank(alice);
        gate.appeal(id1, "Please reconsider my first plea, kind Cabal.");
    }

    // ---------------------------------------------------------------- keeper tip (medium)

    function test_dustSettlementEarnsNoTipAndOneTipPerBlock() public {
        afterLaunchWindow();
        imd.mint(address(this), 100e18);
        imd.approve(address(hook), 100e18);
        hook.fundWall(100e18);
        imd.mint(keeper, 1e18);
        vm.prank(keeper);
        imd.approve(address(router), type(uint256).max);
        uint256 reserve = hook.retainedImd();
        for (uint256 i; i < 5; ++i) {
            buy(keeper, 80); // 80 wei: a 1-wei claim
            nextBlock();
            vm.prank(keeper);
            hook.settleClaims();
        }
        assertEq(hook.retainedImd(), reserve, "no tip for settling dust");
        assertEq(imd.balanceOf(keeper), 1e18 - 5 * 80, "keeper paid for its own dust, earned nothing");
        // real work (>= 0.1 IMD) is tipped, once per block
        buy(alice, 100e18);
        nextBlock();
        vm.prank(keeper);
        hook.rebalance(); // settles ~1.23 IMD of claims then deploys the wall
        assertEq(imd.balanceOf(keeper), 1e18 - 5 * 80 + hook.KEEPER_TIP());
        imd.mint(address(this), 100e18);
        imd.approve(address(hook), 100e18);
        hook.fundWall(100e18);
        vm.prank(keeper);
        hook.rebalance(); // same block: no second tip
        assertEq(imd.balanceOf(keeper), 1e18 - 5 * 80 + hook.KEEPER_TIP());
    }

    // ---------------------------------------------------------------- relayer (medium)

    function test_onlyRelayerDeliversOnceSet() public {
        afterLaunchWindow();
        buy(alice, 10e18);
        nextBlock();
        vm.prank(alice);
        uint256 id = gate.submitSell(1e18, TEXT);
        vm.prank(OWNER);
        gate.setRelayer(keeper);
        OracleAttestation.Attestation memory yes = attestationFor(id, true, keccak256("alice-req"));
        bytes memory sigYes = sign(yes);
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotRelayer.selector);
        gate.deliverVerdict(id, yes, sigYes);
        OracleAttestation.Attestation memory no = attestationFor(id, false, keccak256("relayer-req"));
        bytes memory sigNo = sign(no);
        vm.prank(keeper);
        gate.deliverVerdict(id, no, sigNo);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Denied));
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotOwner.selector);
        gate.setRelayer(alice);
    }

    // ---------------------------------------------------------------- UTF-8 (low)

    function test_illFormedUtf8Rejected() public {
        afterLaunchWindow();
        buy(alice, 10e18);
        nextBlock();
        bytes[4] memory bad = [
            bytes(hex"6162eda080"), // UTF-16 surrogate U+D800
            bytes(hex"6162e080a2"), // overlong 3-byte form
            bytes(hex"6162f0808080"), // overlong 4-byte form
            bytes(hex"6162f4908080") // above U+10FFFF
        ];
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            vm.expectRevert(CabalGate.BadPleaText.selector);
            gate.submitSell(1e18, string(bad[i]));
        }
        vm.prank(alice);
        gate.submitSell(1e18, unicode"ab€😀 fine");
    }

    // ---------------------------------------------------------------- round 3: recipient required (medium)

    function test_exactInBuyWithoutRecipientRefusedWhileAlive() public {
        afterLaunchWindow();
        // no hookData: the PLEA would land in the router, where the Cabal strands it
        vm.prank(bob);
        vm.expectRevert();
        router.buyExactIn(10e18, "");
        // 32 bytes that decode to the zero address are refused too
        vm.prank(bob);
        vm.expectRevert();
        router.buyExactIn(10e18, abi.encode(address(0)));
        // 32 bytes that are not a clean address are refused by the decoder
        vm.prank(bob);
        vm.expectRevert();
        router.buyExactIn(10e18, abi.encode(uint256(1) << 200));
        assertEq(plea.balanceOf(bob), 0);
        assertEq(plea.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(bob), 10_000e18, "a refused buy costs nothing");
        (uint256 spent,) = hook.costBasis(address(router));
        assertEq(spent, 0, "nothing booked for the router");
        // the documented form works
        assertGt(buy(bob, 10e18), 0);
        assertEq(plea.balanceOf(address(router)), 0);
    }

    function test_afterKillCabalPlainRouterBuyReachesBuyer() public {
        skip(49 hours);
        vm.roll(vm.getBlockNumber() + 14_700);
        gate.killCabal();
        assertTrue(plea.cabalDead());
        // standard v4 accounting: the swapper gets a positive PLEA delta and its router takes it to bob
        vm.prank(bob);
        uint256 out = router.buyExactIn(10e18, "");
        assertGt(out, 0);
        assertEq(plea.balanceOf(bob), out);
        assertEq(plea.balanceOf(address(router)), 0, "nothing stranded in the router");
        assertEq(plea.balanceOf(address(hook)), 0);
        (uint256 spent, uint256 held) = hook.costBasis(address(router));
        assertEq(held, out, "basis is booked for the swap sender when no recipient is given");
        assertGt(spent, 0);
        // the 0.25% burn fee was still taken on the PLEA leg (out = gross - gross * 25 / 10000)
        assertApproxEqAbs(hook.pleaBurnClaims(), out * 25 / 9_975, 1);
    }

    // ---------------------------------------------------------------- round 3: tip only for work done (medium)

    function _drainMarketWithGateSell() internal {
        buy(bob, 10e18);
        _claim(alice, 100_000_000e18);
        skip(1 days);
        vm.roll(vm.getBlockNumber() + 7200);
        vm.prank(alice);
        uint256 id = gate.submitSell(2_500_000e18, TEXT);
        deliver(id, true);
        vm.prank(alice);
        uint256 out = gate.executeSell(0);
        assertGt(out, 0);
        assertEq(hook.imdInMarket(), 0, "every IMD position is exhausted");
        int24 tick = hook.currentTick();
        assertTrue(tick == TickMath.MAX_TICK - 1 || tick == TickMath.MIN_TICK, "price at the tick extreme");
    }

    function test_noTipWhileWallCannotDeploy() public {
        afterLaunchWindow();
        _drainMarketWithGateSell();
        imd.mint(address(this), 20e18);
        imd.approve(address(hook), 20e18);
        hook.fundWall(20e18);
        assertTrue(hook.pendingRebalance());
        nextBlock();
        // the first call settles the matured fee claims of the buy and the sell: real work, one tip
        vm.prank(keeper);
        hook.rebalance();
        assertEq(imd.balanceOf(keeper), hook.KEEPER_TIP());
        (,, uint128 liq) = hook.wall();
        assertEq(liq, 0, "the band cannot be placed at the extreme");
        uint256 reserve = hook.retainedImd();
        // from then on nothing is settled, closed or deployed: no tip, and the call says so
        for (uint256 i; i < 10; ++i) {
            nextBlock();
            vm.prank(keeper);
            vm.expectRevert(PleaHook.RebalanceNotNeeded.selector);
            hook.rebalance();
        }
        assertEq(imd.balanceOf(keeper), hook.KEEPER_TIP(), "no tip for doing nothing");
        assertEq(hook.retainedImd(), reserve, "the reserve is not farmed");
        // the next buy brings the price back and the wall deploys (and that call is tipped)
        nextBlock();
        buy(bob, 1e18);
        nextBlock();
        vm.prank(keeper);
        hook.rebalance();
        (,, liq) = hook.wall();
        assertGt(liq, 0);
        assertEq(imd.balanceOf(keeper), 2 * hook.KEEPER_TIP());
        assertLt(hook.retainedImd(), 1e18, "the reserve went into the wall");
    }

    function test_recycledWallEarnsNoTip() public {
        afterLaunchWindow();
        buy(alice, 100e18);
        imd.mint(address(this), 50e18);
        imd.approve(address(hook), 50e18);
        hook.fundWall(50e18);
        nextBlock();
        vm.prank(keeper);
        hook.rebalance();
        assertEq(imd.balanceOf(keeper), hook.KEEPER_TIP());
        // an untouched wall is not pending; nothing to settle either
        nextBlock();
        assertFalse(hook.pendingRebalance());
        vm.prank(keeper);
        vm.expectRevert(PleaHook.RebalanceNotNeeded.selector);
        hook.rebalance();
        assertEq(imd.balanceOf(keeper), hook.KEEPER_TIP());
    }

    // ---------------------------------------------------------------- round 3: partial-fill refund (low)

    function _limitNearSpot() internal view returns (uint160) {
        int24 spot = hook.currentTick();
        return TickMath.getSqrtPriceAtTick(hook.pleaIsZero() ? spot + 120 : spot - 120);
    }

    function _imdFeeFromLogs(Vm.Log[] memory logs) internal pure returns (uint256 basis, uint256 fee) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PleaHook.FeesTaken.selector) {
                (, basis, fee,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            }
        }
    }

    function test_partialFillExactInBuyRefundsWhenPoolManagerHoldsNoImd() public {
        afterLaunchWindow();
        assertEq(imd.balanceOf(address(pm)), 0);
        uint256 imdId = uint256(uint160(address(imd)));
        uint256 before = imd.balanceOf(bob);
        uint160 limit = _limitNearSpot();
        vm.recordLogs();
        vm.prank(bob);
        uint256 out = router.buyExactInLimit(1_000e18, abi.encode(bob), limit);
        assertGt(out, 0);
        (uint256 basis, uint256 fee) = _imdFeeFromLogs(vm.getRecordedLogs());
        assertLt(basis, 100e18, "a partial fill");
        assertEq(fee, basis * 125 / 10_000, "fee on the fill only");
        uint256 specFee = uint256(1_000e18) * 125 / 10_125;
        uint256 refund = specFee - fee;
        // the PoolManager held no IMD to refund from: the refund is an IMD claim the trader owns
        assertEq(before - imd.balanceOf(bob), basis + specFee);
        assertEq(pm.balanceOf(bob, imdId), refund);
        assertGt(refund, 10e18);
        // once the PoolManager holds IMD the refund is paid in ERC-20
        nextBlock();
        before = imd.balanceOf(bob);
        limit = _limitNearSpot();
        vm.recordLogs();
        vm.prank(bob);
        out = router.buyExactInLimit(1_000e18, abi.encode(bob), limit);
        assertGt(out, 0);
        (basis, fee) = _imdFeeFromLogs(vm.getRecordedLogs());
        assertEq(before - imd.balanceOf(bob), basis + fee, "fill plus 1.25% of the fill");
        assertEq(pm.balanceOf(bob, imdId), refund, "no new claims");
    }

    // ---------------------------------------------------------------- in-swap redemption (low)

    function test_nextBlockTradeRedeemsMaturedClaimsEvenWithDustAhead() public {
        afterLaunchWindow();
        uint256 ownerBefore = imd.balanceOf(OWNER);
        buy(alice, 100e18);
        uint256 ownerClaim = hook.imdOwnerClaims();
        assertGt(ownerClaim, 0);
        nextBlock();
        buy(bob, 80); // a dust trade ahead of any keeper still redeems the earlier block's claims
        assertEq(imd.balanceOf(OWNER) - ownerBefore, ownerClaim, "owner paid by the next trade");
        assertGt(hook.cashbackFloat(), 0, "float funded without a keeper");
        assertLt(hook.imdOwnerClaims(), ownerClaim);
        // and the following trade is paid its cashback at trade time
        nextBlock();
        uint256 before = simd.balanceOf(bob);
        buy(bob, 10e18);
        assertEq(simd.balanceOf(bob) - before, cashbackFor(10e18));
    }
}
