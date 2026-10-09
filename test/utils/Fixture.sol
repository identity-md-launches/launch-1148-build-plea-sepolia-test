// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {PLEA} from "../../src/PLEA.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {MockIMD, MockSIMD, MockStacker, BuyRouter} from "./Mocks.sol";

/// @dev Replays the launch: PLEA, CabalGate, PleaDistributor, PleaLaunch in one call context.
contract Fixture is Test {
    address constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    address constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    /// @dev anvil's second account, used as the test oracle signer.
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    PoolManager pm;
    MockIMD imd;
    MockSIMD simd;
    MockStacker stacker;
    PLEA plea;
    CabalGate gate;
    PleaDistributor distributor;
    PleaLaunch launch;
    PleaHook hook;
    BuyRouter router;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        pm = new PoolManager(address(this));
        deployImd();
        simd = new MockSIMD();
        stacker = new MockStacker(imd, simd);
        deployLaunch();
        router = new BuyRouter(IPoolManager(address(pm)), hook, imd, plea);
        imd.mint(alice, 10_000e18);
        imd.mint(bob, 10_000e18);
        vm.prank(alice);
        imd.approve(address(router), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(router), type(uint256).max);
        vm.prank(alice);
        imd.approve(address(gate), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(gate), type(uint256).max);
        vm.prank(alice);
        plea.approve(address(gate), type(uint256).max);
        vm.prank(bob);
        plea.approve(address(gate), type(uint256).max);
        vm.prank(OWNER);
        gate.setSigner(SIGNER);
    }

    /// @dev Default: IMD sorts below PLEA (IMD is currency0, `hook.pleaIsZero() == false`). The
    /// orientation suite overrides this to put IMD at a high address so PLEA is currency0.
    function deployImd() internal virtual {
        imd = new MockIMD();
    }

    function deployLaunch() internal {
        plea = new PLEA(OWNER);
        gate = new CabalGate(address(plea), address(imd), ORACLE_SIGNER);
        distributor = new PleaDistributor(address(plea), OWNER);
        // Not metered here: in this forge build `gasleft()` around a CREATE reports only the call
        // overhead (about 24k), not the constructor's execution. Launch.t.sol measures the real
        // cost with a gas-limit search on a deploying call.
        launch = new PleaLaunch(
            address(plea), address(gate), address(distributor), address(pm), address(imd), address(stacker)
        );
        hook = PleaHook(launch.hook());
    }

    function buy(address who, uint256 imdIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.buyExactIn(imdIn, abi.encode(who));
    }

    /// @dev IMD that reaches the pool for an exact-input buy of `imdIn` now: the fee is a share of the fill.
    function fillOf(uint256 imdIn) internal view returns (uint256) {
        uint256 r = 125 + hook.launchExtraBps();
        return imdIn - imdIn * r / (10_000 + r);
    }

    function cashbackFor(uint256 imdIn) internal view returns (uint256) {
        return fillOf(imdIn) * 50 / 10_000;
    }

    function nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        skip(12);
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, gate.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function attestationFor(uint256 id, bool answer, bytes32 requestId)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        uint64 toBlock = uint64(vm.getBlockNumber());
        uint64 fromBlock = toBlock - 300;
        a = OracleAttestation.Attestation({
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
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 3600)
        });
    }

    function deliver(uint256 id, bool answer) internal {
        OracleAttestation.Attestation memory a = attestationFor(id, answer, keccak256(abi.encode("req", id)));
        gate.deliverVerdict(id, a, sign(a));
    }
}
