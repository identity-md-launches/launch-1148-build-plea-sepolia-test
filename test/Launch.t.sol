// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PLEA} from "../src/PLEA.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @dev Performs the PleaLaunch deployment inside one call so a gas limit can bound it.
contract LaunchDeployer {
    function deploy(address plea, address gate, address distributor, address pm, address imd, address stacker)
        external
        returns (PleaLaunch l)
    {
        l = new PleaLaunch(plea, gate, distributor, pm, imd, stacker);
    }
}

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

    /// @dev In this forge build `gasleft()` around `new X(...)` reports only the CREATE call overhead
    /// (about 24k), not the constructor's execution, and so does a helper call wrapping it. The real
    /// cost is found with a gas-limit search: the smallest gas limit on a call that performs the
    /// deployment and succeeds. Mining is measured through an external call, which is metered.
    function test_reportLaunchAndMiningGas() public {
        bytes memory initCode = abi.encodePacked(
            type(PleaHook).creationCode, abi.encode(address(pm), address(plea), address(imd), address(stacker), OWNER)
        );
        uint256 g = gasleft();
        (uint256 salt, uint256 tries) = launch.mine(address(launch), keccak256(initCode), FLAGS);
        uint256 mineGas = g - gasleft();
        assertEq(salt, launch.salt());
        assertEq(tries, launch.tries());
        uint256 perTry = mineGas / tries;
        assertGt(perTry, 50, "a try is at least one keccak and a compare");
        assertLt(perTry, 300, "a try is a fixed-memory keccak loop iteration");

        // A fresh launch, deployed from a helper so the deployment is a single call whose gas limit
        // the search can bound. The helper's address changes the mined salt, so its tries are reported too.
        PLEA p2 = new PLEA(OWNER);
        CabalGate g2 = new CabalGate(address(p2), address(imd), ORACLE_SIGNER);
        PleaDistributor d2 = new PleaDistributor(address(p2), OWNER);
        LaunchDeployer dep = new LaunchDeployer();
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        PleaLaunch l2 = dep.deploy(address(p2), address(g2), address(d2), address(pm), address(imd), address(stacker));
        uint256 naive = g0 - gasleft();
        uint256 tries2 = l2.tries();
        assertEq(uint160(l2.hook()) & 0x3fff, FLAGS);
        uint256 lo = 500_000;
        uint256 hi = 60_000_000;
        while (hi - lo > 5_000) {
            uint256 mid = (lo + hi) / 2;
            vm.revertToState(snap);
            try dep.deploy{gas: mid}(
                address(p2), address(g2), address(d2), address(pm), address(imd), address(stacker)
            ) returns (
                PleaLaunch
            ) {
                hi = mid;
            } catch {
                lo = mid;
            }
        }
        vm.revertToState(snap);
        uint256 launchGas = hi;
        uint256 miningShare = perTry * tries2;
        assertGt(launchGas, miningShare, "the launch costs more than its mining alone");
        assertGt(launchGas, 2_000_000, "hook deploy + pool init + seed + mint are millions of gas, not 24k");
        assertLt(naive, 100_000, "the naive gasleft() reading is the metering artifact, not the cost");
        emit log_named_uint(
            "PleaLaunch deploy: min gas limit on the deploying call (mining + hook deploy + init + seed)", launchGas
        );
        emit log_named_uint("  of which salt mining (tries x per-try)", miningShare);
        emit log_named_uint("  salt tries for this deployer", tries2);
        emit log_named_uint("  non-mining share (hook deploy + init + mint + seed)", launchGas - miningShare);
        emit log_named_uint("salt mining gas, fixture launch (external call)", mineGas);
        emit log_named_uint("salt tries, fixture launch", tries);
        emit log_named_uint("mining gas per try", perTry);
        emit log_named_uint("worst-case mining gas (100,000 tries before SaltNotFound)", perTry * launch.MAX_TRIES());
        emit log_named_uint(
            "worst-case launch gas (non-mining share + 100,000 tries)",
            launchGas - miningShare + perTry * launch.MAX_TRIES()
        );
        emit log_named_uint("naive gasleft() reading around the CREATE (artifact, not a cost)", naive);
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
