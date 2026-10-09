// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./utils/Fixture.sol";
import {PleaIsZeroFixture} from "./Orientation.t.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PleaHook} from "../src/PleaHook.sol";

/// @dev What a trader needs to turn an ERC-6909 IMD claim into IMD: burn it inside an unlock and take.
contract ClaimRedeemer {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function redeem(address currency, uint256 amount, address to) external {
        pm.unlock(abi.encode(msg.sender, currency, amount, to));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (address from, address currency, uint256 amount, address to) =
            abi.decode(raw, (address, address, uint256, address));
        pm.burn(from, uint256(uint160(currency)), amount);
        pm.take(Currency.wrap(currency), to, amount);
        return "";
    }
}

/*
  The specified-side fee is taken in beforeSwap on the whole input and settled against the fill in
  afterSwap: the part the fill did not earn comes back, as ERC-20 IMD when the PoolManager can pay and
  as an ERC-6909 IMD claim when it cannot (right after launch it holds no IMD at all). These
  properties fuzz the fill fraction through the price limit and check, from the trader's side only,
  that a partial buy costs exactly fill + 1.25% of the fill, that the refund is real money in both
  forms, and that the buyer never ends up holding a PLEA claim.
*/
abstract contract RefundProperties is Fixture {
    function afterLaunchWindow() internal {
        skip(91 minutes);
        vm.roll(vm.getBlockNumber() + 450);
    }

    function _limitTicksFromSpot(int24 ticks) internal view returns (uint160) {
        int24 spot = hook.currentTick();
        return TickMath.getSqrtPriceAtTick(hook.pleaIsZero() ? spot + ticks : spot - ticks);
    }

    function _feesTaken(Vm.Log[] memory logs) internal pure returns (uint256 basis, uint256 fee, uint256 pleaFee) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PleaHook.FeesTaken.selector) {
                (, basis, fee, pleaFee) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            }
        }
    }

    function _refunded(Vm.Log[] memory logs) internal pure returns (uint256 amount, bool asClaims, bool seen) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PleaHook.FeeRefunded.selector) {
                (, amount, asClaims) = abi.decode(logs[i].data, (address, uint256, bool));
                seen = true;
            }
        }
    }

    function testFuzz_partialBuyCostsFillPlusFeeOnFill(uint256 imdIn, uint24 ticks) public {
        afterLaunchWindow();
        imdIn = bound(imdIn, 1e15, 5_000e18);
        ticks = uint24(bound(ticks, 1, 6_000));
        imd.mint(alice, imdIn);
        uint256 imdId = uint256(uint160(address(imd)));
        uint256 wallet = imd.balanceOf(alice);
        uint256 pmImd = imd.balanceOf(address(pm));
        uint160 limit = _limitTicksFromSpot(int24(ticks));
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = router.buyExactInLimit(imdIn, abi.encode(alice), limit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 basis, uint256 fee, uint256 pleaFee) = _feesTaken(logs);
        (uint256 refund, bool asClaims, bool refunded) = _refunded(logs);

        // the fee is 1.25% of what the pool actually took, never of the gross input
        assertEq(fee, basis * 125 / 10_000, "fee on the fill");
        assertLe(basis + fee, imdIn, "cost bounded by the input");
        // what alice parted with, counting a claim refund as money kept, is the fill plus its fee
        uint256 parted = wallet - imd.balanceOf(alice);
        uint256 claims = pm.balanceOf(alice, imdId);
        assertEq(parted - claims, basis + fee, "trader cost != fill + fee");
        // the refund is the whole fee overcharge, and a claim is used only when ERC-20 was impossible
        uint256 specFee = imdIn * 125 / 10_125;
        if (specFee > fee) {
            assertTrue(refunded, "an overcharge was not refunded");
            assertEq(refund, specFee - fee, "refund != overcharge");
            if (asClaims) {
                assertEq(claims, refund);
                assertLt(pmImd, refund, "claims used although the PoolManager held the IMD");
            } else {
                assertEq(claims, 0);
            }
        } else {
            assertEq(claims, 0);
        }
        // the PLEA leg: alice got the fill minus the 0.25% burn, as ERC-20, and holds no PLEA claim
        assertEq(plea.balanceOf(alice), out);
        assertEq(pleaFee, (out + pleaFee) * 25 / 10_000, "burn fee on the PLEA leg");
        assertEq(pm.balanceOf(alice, uint256(uint160(address(plea)))), 0, "buyer holds PLEA claims");
        (uint256 spent, uint256 held) = hook.costBasis(alice);
        assertEq(spent, basis + fee, "basis booked gross of the fee on the fill");
        assertEq(held, out);
    }

    /// @notice A claim refund is redeemable for the same IMD by any unlock-capable contract.
    function test_claimRefundRedeemsToImd() public {
        afterLaunchWindow();
        assertEq(imd.balanceOf(address(pm)), 0, "nothing to pay an ERC-20 refund from yet");
        uint256 imdId = uint256(uint160(address(imd)));
        uint160 limit = _limitTicksFromSpot(120);
        vm.prank(alice);
        router.buyExactInLimit(1_000e18, abi.encode(alice), limit);
        uint256 claims = pm.balanceOf(alice, imdId);
        assertGt(claims, 0, "the refund came as a claim");
        ClaimRedeemer redeemer = new ClaimRedeemer(IPoolManager(address(pm)));
        vm.prank(alice);
        pm.setOperator(address(redeemer), true);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        redeemer.redeem(address(imd), claims, alice);
        assertEq(imd.balanceOf(alice) - before, claims, "the claim paid out in IMD");
        assertEq(pm.balanceOf(alice, imdId), 0);
        // redeeming it twice is impossible: the claim is gone
        vm.prank(alice);
        vm.expectRevert();
        redeemer.redeem(address(imd), claims, alice);
    }

    /// @notice The refund path never changes what the hook itself ends up holding: the IMD and PLEA
    /// claims the hook books after a partial fill are exactly the fees on the fill.
    function test_partialBuyBooksOnlyTheFeeOnTheFill() public {
        afterLaunchWindow();
        uint160 limit = _limitTicksFromSpot(120);
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = router.buyExactInLimit(1_000e18, abi.encode(alice), limit);
        (uint256 basis, uint256 fee, uint256 pleaFee) = _feesTaken(vm.getRecordedLogs());
        assertGt(out, 0);
        assertLt(basis, 1_000e18 * 9_000 / 10_000, "the limit made it a partial fill");
        assertEq(hook.imdOwnerClaims() + hook.imdCashbackClaims() + hook.imdRetainClaims(), fee);
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(imd)))), fee, "hook IMD claims != fee");
        assertEq(hook.pleaBurnClaims(), pleaFee);
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(plea)))), pleaFee, "hook PLEA claims != burn");
        assertEq(hook.imdCashbackClaims(), basis * 50 / 10_000, "cashback on the fill");
        assertEq(hook.cashbackOwed(alice), basis * 50 / 10_000, "first trade: cashback owed, on the fill");
    }
}

/// forge-config: default.fuzz.runs = 200
contract RefundsImdIsZeroTest is RefundProperties {}

/// forge-config: default.fuzz.runs = 200
contract RefundsPleaIsZeroTest is PleaIsZeroFixture, RefundProperties {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }
}
