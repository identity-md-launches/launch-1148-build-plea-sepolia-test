// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PLEA} from "../src/PLEA.sol";
import {PleaHook} from "../src/PleaHook.sol";

contract HookTest is Fixture {
    function afterLaunchWindow() internal {
        skip(91 minutes);
        vm.roll(vm.getBlockNumber() + 450);
    }

    function test_seedPriceIsFiveThousandSevenHundredImdCap() public view {
        // market cap = supply * price = 1e9 * (IMD per PLEA)
        uint256 cap = hook.priceX96() * 1_000_000_000 / (1 << 96);
        assertApproxEqRel(cap, 5_700, 2e16); // within tick rounding (0.6% per 60-tick step)
        assertEq(hook.imdInMarket(), 0);
        assertEq(hook.launchExtraBps(), 7_000);
    }

    function test_buyTakesFeesAndRecordsBasis() public {
        afterLaunchWindow();
        uint256 imdIn = 100e18;
        uint256 ownerBefore = imd.balanceOf(OWNER);
        uint256 fill = fillOf(imdIn);
        uint256 fee = imdIn - fill;
        uint256 out = buy(alice, imdIn);
        assertGt(out, 0);
        assertEq(plea.balanceOf(alice), out);
        // IMD fee 1.25% of the fill (what reached the pool), split 0.5 / 0.5 / 0.25
        assertEq(hook.imdOwnerClaims(), fill * 50 / 10_000);
        assertEq(hook.imdCashbackClaims(), fill * 50 / 10_000);
        assertEq(hook.imdRetainClaims(), fee - 2 * (fill * 50 / 10_000));
        assertApproxEqAbs(fee, fill * 125 / 10_000, 1, "fee is 1.25% of the fill");
        // 0.25% of the PLEA leg burned: alice got the pool output minus the burn fee as ERC-20
        uint256 burn = hook.pleaBurnClaims();
        assertEq(burn, (out + burn) * 25 / 10_000, "burn fee");
        (uint256 spent, uint256 held) = hook.costBasis(alice);
        assertEq(spent, imdIn);
        assertEq(held, out);
        // first trade: no float yet, cashback is owed
        assertEq(hook.cashbackOwed(alice), fill * 50 / 10_000);
        // next block: settle realises claims, owner paid, float funded, PLEA burned
        nextBlock();
        uint256 supplyBefore = plea.totalSupply();
        hook.settleClaims();
        assertEq(imd.balanceOf(OWNER) - ownerBefore, fill * 50 / 10_000);
        assertEq(hook.cashbackFloat(), fill * 50 / 10_000);
        assertEq(hook.retainedImd(), fee - 2 * (fill * 50 / 10_000) - hook.KEEPER_TIP()); // settle tip paid
        assertLt(plea.totalSupply(), supplyBefore);
        assertEq(hook.pleaBurnClaims(), 0);
        // owed cashback is now claimable, as sIMD
        vm.prank(alice);
        hook.claimCashback();
        assertEq(simd.balanceOf(alice), fill * 50 / 10_000);
        assertEq(simd.byProject(alice, address(hook)), fill * 50 / 10_000);
    }

    function test_cashbackStackedAtTradeTimeOnceFloatExists() public {
        afterLaunchWindow();
        buy(alice, 100e18);
        nextBlock();
        hook.settleClaims();
        uint256 before = simd.balanceOf(bob);
        buy(bob, 50e18);
        assertEq(simd.balanceOf(bob) - before, cashbackFor(50e18));
        assertEq(simd.byProject(bob, address(hook)), cashbackFor(50e18));
        assertEq(hook.cashbackOwed(bob), 0);
    }

    function test_cashbackFallsBackToPlainImdWhenSimdPaused() public {
        afterLaunchWindow();
        buy(alice, 100e18);
        nextBlock();
        hook.settleClaims();
        simd.setPaused(true);
        uint256 imdBefore = imd.balanceOf(bob);
        uint256 out = buy(bob, 50e18);
        assertGt(out, 0, "trade still succeeds");
        assertEq(imd.balanceOf(bob), imdBefore - 50e18 + cashbackFor(50e18), "plain IMD cashback");
        assertEq(simd.balanceOf(bob), 0);
    }

    function test_cashbackFallsBackWhenCreditStarvedOfGas() public {
        afterLaunchWindow();
        buy(alice, 100e18);
        nextBlock();
        hook.settleClaims();
        stacker.setBurnAllGas(true); // credit swallows every gas unit it is given
        uint256 imdBefore = imd.balanceOf(bob);
        uint256 out = buy(bob, 50e18);
        assertGt(out, 0, "trade still succeeds with RESERVE left for the fallback");
        assertEq(imd.balanceOf(bob), imdBefore - 50e18 + cashbackFor(50e18));
    }

    function test_cashbackOwedWhenPlainTransferImpossible() public {
        afterLaunchWindow();
        buy(alice, 100e18);
        nextBlock();
        hook.settleClaims();
        simd.setPaused(true);
        // drain the hook's real IMD so even the plain transfer fails: trade must still succeed
        uint256 hookBal = imd.balanceOf(address(hook));
        vm.prank(address(hook));
        imd.transfer(address(0xdead), hookBal);
        uint256 out = buy(bob, 50e18);
        assertGt(out, 0);
        assertEq(hook.cashbackOwed(bob), cashbackFor(50e18));
    }

    function test_launchFeeDecaysLinearlyAndGoesToPool() public {
        assertEq(hook.launchExtraBps(), 7_000);
        skip(45 minutes);
        assertEq(hook.launchExtraBps(), 3_500);
        uint256 imdIn = 10e18;
        uint256 fill = fillOf(imdIn);
        buy(alice, imdIn);
        // the extra fee is charged on the fill: fee / fill == 1.25% + 35%
        assertEq(hook.imdRetainClaims(), (imdIn - fill) - 2 * (fill * 50 / 10_000));
        assertApproxEqAbs(imdIn - fill, fill * 3_625 / 10_000, 1);
        skip(45 minutes);
        assertEq(hook.launchExtraBps(), 0);
    }

    function test_launchMaxBuyEnforcedThenLifted() public {
        imd.mint(alice, 1_000_000e18);
        vm.prank(alice);
        vm.expectRevert();
        router.buyExactIn(1_000e18, abi.encode(alice)); // far more than 5,000,000 PLEA at the seed price
        uint256 got = buy(alice, 10e18);
        assertLe(got, 5_000_000e18);
        afterLaunchWindow();
        uint256 big = buy(alice, 1_000e18);
        assertGt(big, 5_000_000e18);
    }

    function test_exactOutputBuysRefusedWhileCabalLivesAndCostTheSameAfter() public {
        afterLaunchWindow();
        // alive: an exact-output buy would leave the swapper a positive PLEA delta (claims), so it is refused
        vm.prank(alice);
        vm.expectRevert();
        router.buyExactOut(1_000_000e18, abi.encode(alice));
        // dead: both ways of buying the same PLEA cost the same within tick rounding
        skip(48 hours + 1);
        nextBlock();
        gate.killCabal();
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        uint256 costOut = router.buyExactOut(1_000_000e18, abi.encode(bob));
        assertEq(plea.balanceOf(bob), 1_000_000e18);
        vm.revertToState(snap);
        uint256 lo = 1e18;
        uint256 hi = 100e18;
        for (uint256 i; i < 40; ++i) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(snap);
            uint256 g = buy(alice, mid);
            if (g < 1_000_000e18) lo = mid;
            else hi = mid;
        }
        assertApproxEqRel(hi, costOut, 2e16, "same fill, same cost either way");
    }

    function test_sellsOnlyViaGateWhileCabalLives() public {
        afterLaunchWindow();
        uint256 out = buy(alice, 100e18);
        vm.prank(alice);
        plea.approve(address(router), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        router.sellExactIn(out / 2, abi.encode(alice));
        // direct transfer to the PoolManager (a v2-style pair deposit) is refused too
        vm.prank(alice);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(pm), 1);
        // and to any other wallet or router
        vm.prank(alice);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(bob, 1);
    }

    function test_hooklessPoolCannotBeUsed() public {
        afterLaunchWindow();
        buy(alice, 100e18);
        // nobody can pay a hookless pool: the PoolManager never receives PLEA from a holder
        uint256 bal = plea.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(pm), bal);
    }

    function test_trimBurnsAndBuildsWall() public {
        afterLaunchWindow();
        skip(1 days);
        uint256 capBefore = hook.inventoryCap();
        uint256 out = buy(alice, 1e18); // opens ~175k PLEA of room: within the day's 300k allowance
        uint256 cap = hook.inventoryCap();
        assertEq(cap, hook.pleaInMarket(), "cap ratcheted down to what is held");
        uint256 allowance = 300_000e18 * (1 days + 91 minutes + 12) / 1 days;
        assertGe(cap, capBefore - allowance);
        // a bigger buy is rate limited: the cap cannot fall more than the allowance
        nextBlock();
        imd.mint(alice, 10_000e18);
        buy(alice, 100e18);
        assertGe(hook.inventoryCap(), capBefore - allowance - 10e18); // carried sub-second remainder
        assertGt(hook.inventoryCap(), hook.pleaInMarket());
        assertEq(hook.pendingTrim(), 0);
        // selling back through the gate pushes PLEA above the cap: the excess is trimmed and burned
        nextBlock();
        skip(1 days);
        buy(alice, 1e18); // ratchet again so held == cap
        cap = hook.inventoryCap();
        uint256 supply = plea.totalSupply();
        uint256 amount = out / 2;
        _approvedSell(alice, amount);
        assertLe(hook.pleaInMarket(), cap + 1e18, "held back at the cap");
        assertGt(hook.pleaBurnClaims(), amount * 25 / 10_000 * 2, "trim claimed more than the burn fee");
        assertGt(hook.imdRetainClaims(), 0, "IMD recovered by the trim");
        nextBlock();
        hook.settleClaims();
        assertLt(plea.totalSupply(), supply - amount * 25 / 10_000, "trimmed PLEA burned");
        assertGt(hook.retainedImd(), 0, "trim IMD retained for the wall");
        imd.mint(address(this), 5e18);
        imd.approve(address(hook), 5e18);
        hook.fundWall(5e18); // over the 1 IMD rebalance threshold
        // the keeper deploys the wall below the price, IMD-only
        uint256 keeperBefore = imd.balanceOf(keeper);
        vm.prank(keeper);
        hook.rebalance();
        (,, uint128 wallLiq) = hook.wall();
        assertGt(wallLiq, 0);
        assertEq(hook.pleaInWall(), 0, "wall holds no PLEA when placed");
        assertEq(imd.balanceOf(keeper) - keeperBefore, hook.KEEPER_TIP(), "keeper tipped");
        assertLt(hook.retainedImd(), 1e18);
    }

    function test_wallFillsAndIsBurnedOnRebalance() public {
        afterLaunchWindow();
        imd.mint(alice, 100_000e18);
        uint256 out = buy(alice, 300e18); // pump
        for (uint256 i; i < 12; ++i) {
            nextBlock();
            buy(bob, 1e17); // the lagging reference tick catches up, 200 ticks per block
        }
        imd.mint(address(this), 100e18);
        imd.approve(address(hook), 100e18);
        hook.fundWall(100e18);
        hook.rebalance();
        (,, uint128 wallLiq) = hook.wall();
        assertGt(wallLiq, 0);
        assertEq(hook.pleaInWall(), 0);
        // once the Cabal is dead, a dump through any router runs the price down into the wall
        skip(48 hours + 1);
        nextBlock();
        gate.killCabal();
        vm.prank(alice);
        plea.approve(address(router), type(uint256).max);
        vm.prank(alice);
        router.sellExactIn(out, abi.encode(alice));
        uint256 filled = hook.pleaInWall();
        assertGt(filled, 0, "wall bought PLEA");
        uint256 supply = plea.totalSupply();
        nextBlock();
        hook.rebalance();
        assertLt(plea.totalSupply(), supply, "wall's PLEA burned");
        assertEq(hook.pleaInWall(), 0);
    }

    function test_rebalanceRevertsWhenNothingToDo() public {
        vm.expectRevert(PleaHook.RebalanceNotNeeded.selector);
        hook.rebalance();
    }

    function test_priceCheckpointsAndPrice24hAgo() public {
        afterLaunchWindow();
        assertEq(hook.price24hAgo(), 0);
        uint256 p0 = hook.priceX96();
        buy(alice, 10e18);
        skip(25 hours);
        nextBlock();
        buy(alice, 10e18);
        uint256 ago = hook.price24hAgo();
        assertGt(ago, 0);
        assertLe(ago, hook.priceX96());
        assertGe(ago, p0);
        // the ring holds 25 slots: 30 hourly trades later the oldest is overwritten but 24h ago still resolves
        for (uint256 i; i < 30; ++i) {
            skip(1 hours);
            nextBlock();
            buy(alice, 1e18);
        }
        assertGt(hook.price24hAgo(), ago);
    }

    function test_liquidityIsLockedForever() public view {
        // no closeMarket / withdraw entry points exist on the hook
        bytes4 close = bytes4(keccak256("closeMarket(address)"));
        bytes4 withdraw = bytes4(keccak256("withdrawRetainedEth(address,uint256)"));
        assertEq(address(hook).code.length > 0, true);
        assertFalse(_hasSelector(address(hook).code, close));
        assertFalse(_hasSelector(address(hook).code, withdraw));
    }

    function test_afterKillCabalSellsFlowAnywhere() public {
        afterLaunchWindow();
        uint256 out = buy(alice, 100e18);
        skip(48 hours + 1);
        gate.killCabal();
        assertTrue(plea.cabalDead());
        vm.prank(alice);
        plea.transfer(bob, out / 10);
        vm.prank(alice);
        plea.approve(address(router), type(uint256).max);
        vm.prank(alice);
        uint256 imdOut = router.sellExactIn(out / 10, abi.encode(alice));
        assertGt(imdOut, 0);
    }

    function _hasSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    /// @dev Plead, get approved by the (test) Cabal and execute.
    function _approvedSell(address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        uint256 id = gate.submitSell(amount, "Sincerely, I must pay rent. Long live the Cabal.");
        deliver(id, true);
        vm.prank(who);
        out = gate.executeSell(0);
    }
}
