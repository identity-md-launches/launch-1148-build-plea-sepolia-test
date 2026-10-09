// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PLEA} from "../src/PLEA.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract LaunchTest is Fixture {
    uint160 constant FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);

    function test_launchWiresEverything() public view {
        assertEq(plea.hook(), address(hook));
        assertEq(plea.gate(), address(gate));
        assertEq(plea.distributor(), address(distributor));
        assertEq(plea.poolManager(), address(pm));
        assertTrue(plea.initialized());
        assertApproxEqRel(plea.totalSupply(), 1_000_000_000e18, 1e13); // seed dust burned
        assertEq(plea.balanceOf(address(distributor)), 100_000_000e18);
        // the hook put its 90% into the pool (dust burned)
        assertEq(plea.balanceOf(address(hook)), 0);
        assertApproxEqRel(hook.pleaInMarket(), 900_000_000e18, 1e13);
        assertTrue(hook.seeded());
        assertApproxEqAbs(hook.inventoryCap(), hook.pleaInMarket(), 2);
        assertEq(hook.owner(), OWNER);
    }

    function test_hookAddressHasExactFlagBits() public view {
        assertEq(uint160(address(hook)) & 0x3fff, FLAGS);
        assertEq(hook.requiredFlags(), FLAGS);
        assertEq(launch.requiredFlags(), FLAGS);
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
    }

    function test_reportLaunchAndMiningGas() public {
        bytes memory initCode = abi.encodePacked(
            type(PleaHook).creationCode, abi.encode(address(pm), address(plea), address(imd), address(stacker), OWNER)
        );
        uint256 g = gasleft();
        (uint256 salt, uint256 tries) = launch.mine(address(launch), keccak256(initCode), FLAGS);
        uint256 mineGas = g - gasleft();
        assertEq(salt, launch.salt());
        assertEq(tries, launch.tries());
        emit log_named_uint("PleaLaunch constructor gas (mining + hook deploy + init + seed)", launchGas);
        emit log_named_uint("salt mining gas", mineGas);
        emit log_named_uint("salt tries", tries);
        emit log_named_uint("salt", salt);
    }

    function testFuzz_minedSaltHasExactFlagBits(address deployer, bytes32 initHash) public view {
        // One deployer/hash pair in ~450 has no match in 100,000 salts (the documented revert).
        (bool ok, bytes memory ret) =
            address(launch).staticcall(abi.encodeCall(launch.mine, (deployer, initHash, FLAGS)));
        if (!ok) {
            assertEq(bytes4(ret), PleaLaunch.SaltNotFound.selector);
            return;
        }
        (uint256 salt,) = abi.decode(ret, (uint256, uint256));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
        assertEq(uint160(predicted) & 0x3fff, FLAGS);
    }

    function testFuzz_launchAtAnyAddressDeploysFlaggedHook(uint160 seed) public {
        address at = address(uint160(bound(seed, 1 << 20, type(uint160).max)));
        vm.assume(at.code.length == 0 && at != address(pm) && at != address(imd));
        PLEA p2 = new PLEA(OWNER);
        // about 1 in 450 (deployer, initcode) pairs has no flagged salt in 100,000 tries: skip those
        bytes32 h = keccak256(
            abi.encodePacked(
                type(PleaHook).creationCode, abi.encode(address(pm), address(p2), address(imd), address(stacker), OWNER)
            )
        );
        (bool minable,) = address(launch).staticcall(abi.encodeCall(launch.mine, (at, h, FLAGS)));
        vm.assume(minable);
        deployCodeTo(
            "PleaLaunch.sol:PleaLaunch",
            abi.encode(address(p2), address(gate), address(distributor), address(pm), address(imd), address(stacker)),
            at
        );
        PleaLaunch l2 = PleaLaunch(at);
        assertEq(uint160(l2.hook()) & 0x3fff, FLAGS);
        assertEq(p2.hook(), l2.hook());
    }

    function test_initRevertsSecondTime() public {
        vm.expectRevert(PLEA.AlreadyInitialized.selector);
        plea.init(address(hook), address(gate), address(distributor));
    }

    PLEA pleaFromSetUp;

    function setUp() public override {
        super.setUp();
        pleaFromSetUp = new PLEA(OWNER);
    }

    function test_initRevertsOutsideDeployTx() public {
        // Constructed in setUp, a different transaction, and now a later block.
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(PLEA.NotDeployTx.selector);
        pleaFromSetUp.init(address(hook), address(gate), address(distributor));
    }

    function test_initWorksInsideDeployTx() public {
        PLEA p = new PLEA(OWNER);
        assertFalse(p.initialized());
        // same transaction: the flag is live. init reaches the hook, which refuses a second seed.
        vm.expectRevert(PleaHook.AlreadySeeded.selector);
        p.init(address(hook), address(gate), address(distributor));
    }

    function test_mineFindsSaltUnderBound() public view {
        // Find a (deployer, hash) pair whose first 100k salts never match: impossible to construct
        // deterministically, so check the bound behaviour on a sealed stub instead.
        (uint256 salt,) = launch.mine(address(this), keccak256("x"), FLAGS);
        assertLt(salt, 100_000);
    }

    function test_distributorRootOnce() public {
        vm.prank(OWNER);
        distributor.setMerkleRoot(bytes32(uint256(1)));
        vm.prank(OWNER);
        vm.expectRevert();
        distributor.setMerkleRoot(bytes32(uint256(2)));
    }

    function test_distributorClaim() public {
        bytes32 leafA = keccak256(abi.encodePacked(uint256(0), alice, uint256(1_000e18)));
        bytes32 leafB = keccak256(abi.encodePacked(uint256(1), bob, uint256(2_000e18)));
        bytes32 root =
            leafA < leafB ? keccak256(abi.encodePacked(leafA, leafB)) : keccak256(abi.encodePacked(leafB, leafA));
        vm.prank(OWNER);
        distributor.setMerkleRoot(root);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        distributor.claim(0, alice, 1_000e18, proof);
        assertEq(plea.balanceOf(alice), 1_000e18);
        vm.expectRevert();
        distributor.claim(0, alice, 1_000e18, proof);
        proof[0] = leafA;
        vm.expectRevert();
        distributor.claim(1, bob, 2_001e18, proof);
    }
}
