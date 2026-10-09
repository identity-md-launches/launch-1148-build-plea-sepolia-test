// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {HookTest} from "./Hook.t.sol";
import {GateTest} from "./Gate.t.sol";
import {ReviewTest} from "./Review.t.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {PLEA} from "../src/PLEA.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/*
  On Sepolia the factory-created PLEA address may sort below TestIMD (0x2b69...), which makes PLEA
  currency0 of the pool (`hook.pleaIsZero() == true`) and selects the other branch in seed(),
  _pleaIn/_imdIn, _applyCap, _rebalance and CabalGate.unlockCallback. The default fixture only ever
  lands on IMD-as-currency0. This file runs every hook, gate and review test again with IMD etched at
  the highest address, so PLEA is currency0, and adds explicit checks of what each orientation must
  place where.
*/

/// @dev Mixin: puts IMD at the top of the address space so PLEA sorts first.
abstract contract PleaIsZeroFixture is Fixture {
    address constant HIGH_IMD = address(type(uint160).max);

    function deployImd() internal virtual override {
        deployCodeTo("Mocks.sol:MockIMD", "", HIGH_IMD);
        imd = MockIMD(HIGH_IMD);
    }

    function test_orientationIsPleaZero() public view {
        assertTrue(hook.pleaIsZero(), "PLEA must be currency0 in this suite");
        assertLt(uint160(address(plea)), uint160(address(imd)));
        PoolKey memory key = hook.poolKey();
        assertEq(Currency.unwrap(key.currency0), address(plea));
        assertEq(Currency.unwrap(key.currency1), address(imd));
    }
}

contract HookPleaIsZeroTest is PleaIsZeroFixture, HookTest {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }
}

contract GatePleaIsZeroTest is PleaIsZeroFixture, GateTest {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }

    function setUp() public override(Fixture, GateTest) {
        GateTest.setUp();
    }
}

contract ReviewPleaIsZeroTest is PleaIsZeroFixture, ReviewTest {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }
}

/// @dev Orientation-specific placement checks, run once per orientation.
abstract contract OrientationChecks is Fixture {
    string constant TEXT = "Dear Cabal, the orientation suite asks to sell a little.";

    function afterLaunchWindow() internal {
        skip(91 minutes);
        vm.roll(vm.getBlockNumber() + 450);
    }

    function expectPleaIsZero() internal pure virtual returns (bool);

    function test_orientationMatchesAddressOrder() public view {
        assertEq(hook.pleaIsZero(), expectPleaIsZero());
        assertEq(hook.pleaIsZero(), address(plea) < address(imd));
    }

    /// @notice The market band holds PLEA only, on the PLEA side of the initial price, in both orientations.
    function test_seedBandIsPleaOnlyOnThePleaSide() public view {
        (int24 lower, int24 upper, uint128 liq) = hook.market();
        assertGt(liq, 0);
        int24 tick = hook.currentTick();
        if (hook.pleaIsZero()) {
            // token0 only: price below the band (tick < lower), band extends to the max tick
            assertLt(tick, lower, "price must sit below a token0-only band");
            assertEq(upper, hook.maxTick());
        } else {
            // token1 only: price at or above the band (tick >= upper), band extends to the min tick
            assertGe(tick, upper, "price must sit at or above a token1-only band");
            assertEq(lower, hook.minTick());
        }
        assertEq(hook.imdInMarket(), 0, "seeded with PLEA only");
        assertApproxEqRel(hook.pleaInMarket(), 900_000_000e18, 1e13);
        // the seed price is the 5,700 IMD market cap, within one 60-tick step
        uint256 cap = hook.priceX96() * 1_000_000_000 / (1 << 96);
        assertApproxEqRel(cap, 5_700, 2e16);
    }

    /// @notice A buy raises the IMD-per-PLEA price and a gated sell lowers it, whichever token is currency0.
    function test_buyRaisesAndGateSellLowersPrice() public {
        afterLaunchWindow();
        uint256 p0 = hook.priceX96();
        uint256 out = buy(alice, 50e18);
        uint256 p1 = hook.priceX96();
        assertGt(p1, p0, "buy moves the price up");
        assertGt(hook.imdInMarket(), 0, "IMD entered the market band");
        nextBlock();
        vm.prank(alice);
        uint256 id = gate.submitSell(out / 4, TEXT);
        deliver(id, true);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 got = gate.executeSell(0);
        assertGt(got, 0);
        assertEq(imd.balanceOf(alice) - imdBefore, got, "seller paid in IMD");
        assertLt(hook.priceX96(), p1, "sell moves the price down");
        assertEq(plea.balanceOf(address(gate)), 0, "gate keeps no PLEA");
    }

    /// @notice The wall is placed below the price, IMD only, on the IMD side, in both orientations,
    /// and a dump into it leaves it holding PLEA that the next rebalance burns.
    function test_wallSitsBelowPriceImdOnly() public {
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
        (int24 lower, int24 upper, uint128 liq) = hook.wall();
        assertGt(liq, 0, "wall deployed");
        int24 tick = hook.currentTick();
        if (hook.pleaIsZero()) {
            // IMD is token1: a token1-only band sits below the price (tick >= upper)
            assertGe(tick, upper, "wall below the price");
            assertEq(lower, hook.minTick());
        } else {
            // IMD is token0: a token0-only band sits above the tick (tick < lower), i.e. below the IMD/PLEA price
            assertLt(tick, lower, "wall below the price");
            assertEq(upper, hook.maxTick());
        }
        assertEq(hook.pleaInWall(), 0, "IMD only");
        assertGt(hook.wallImd(), 0);
        assertLt(hook.retainedImd(), 1e18, "reserve deployed");
        // once the Cabal is dead a dump through any router runs the price down into the wall
        skip(48 hours + 1);
        nextBlock();
        gate.killCabal();
        vm.prank(alice);
        plea.approve(address(router), type(uint256).max);
        vm.prank(alice);
        router.sellExactIn(out, abi.encode(alice));
        assertGt(hook.pleaInWall(), 0, "the wall bought PLEA from the dump");
        uint256 supply = plea.totalSupply();
        nextBlock();
        hook.rebalance();
        assertLt(plea.totalSupply(), supply, "the wall's PLEA was burned");
        assertEq(hook.pleaInWall(), 0);
    }

    /// @notice Trims remove PLEA above the cap on the correct side and recover IMD in both orientations.
    function test_trimRecoversImdOnTheRightSide() public {
        afterLaunchWindow();
        skip(1 days);
        uint256 out = buy(alice, 1e18); // ~175k PLEA: within the day's 300k decay allowance, cap ratchets to held
        assertEq(hook.inventoryCap(), hook.pleaInMarket());
        nextBlock();
        uint256 cap = hook.inventoryCap();
        uint256 supply = plea.totalSupply();
        vm.prank(alice);
        uint256 id = gate.submitSell(out * 3 / 10, TEXT);
        deliver(id, true);
        vm.prank(alice);
        gate.executeSell(0);
        assertLe(hook.pleaInMarket(), cap + hook.MIN_TRIM(), "excess trimmed back to the cap");
        assertGt(hook.pleaBurnClaims(), 0, "trimmed PLEA claimed for burning");
        assertGt(hook.imdRetainClaims(), 0, "IMD recovered by the trim");
        nextBlock();
        hook.settleClaims();
        assertLt(plea.totalSupply(), supply, "trimmed PLEA burned");
        assertEq(plea.balanceOf(address(hook)), 0, "hook holds no PLEA of its own");
    }

    /// @notice Direct deposits to the PoolManager and hookless pools are refused in both orientations.
    function test_noBypassInEitherOrientation() public {
        afterLaunchWindow();
        uint256 out = buy(alice, 10e18);
        vm.prank(alice);
        plea.approve(address(router), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        router.sellExactIn(out / 2, abi.encode(alice));
        vm.prank(alice);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(pm), out / 2);
    }
}

contract OrientationImdIsZeroTest is OrientationChecks {
    function expectPleaIsZero() internal pure override returns (bool) {
        return false;
    }
}

contract OrientationPleaIsZeroTest is PleaIsZeroFixture, OrientationChecks {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }

    function expectPleaIsZero() internal pure override returns (bool) {
        return true;
    }
}
