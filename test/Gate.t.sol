// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PLEA} from "../src/PLEA.sol";

contract GateTest is Fixture {
    string constant TEXT = "Dear Cabal, I bought early and held through the dip; I need 10% for my sister's wedding.";

    function setUp() public override {
        super.setUp();
        skip(91 minutes);
        vm.roll(vm.getBlockNumber() + 450);
        buy(alice, 10e18); // ~1.7M PLEA at the 5,700 IMD cap
        buy(bob, 5e18);
    }

    function _submit(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = gate.submitSell(amount, TEXT);
    }

    function test_submitTakesFeeAndEmitsBody() public {
        uint256 bal = plea.balanceOf(alice);
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 id = _submit(alice, bal / 10);
        assertEq(imd.balanceOf(alice), imdBefore - 0.5e18);
        assertEq(imd.balanceOf(address(gate)), 0.5e18);
        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(uint8(p.status), uint8(CabalGate.Status.Pending));
        assertEq(p.need, 70 - p.factScore);
        assertEq(gate.pendingOf(alice), id);
        string memory b = gate.body(id);
        assertTrue(bytes(b).length > 500);
        assertTrue(_contains(b, '"consumer":{"chainId":11155111,"address":"'));
        assertTrue(_contains(b, "[PLEA]Dear Cabal"));
        assertTrue(_contains(b, '"panelSize":30,"quorum":20,"validForSeconds":3600,"allowAmbiguous":true'));
        string memory c = gate.canonical(id, 1, 2);
        assertTrue(_contains(c, '{"answerType":"bool","chainId":1,"definitions":{"facts":"'));
        assertTrue(_contains(c, '","v":1,"window":{"fromBlock":1,"toBlock":2}}'));
    }

    function test_factScoreComponents() public {
        uint256 bal = plea.balanceOf(alice);
        // just bought: share <=15% -> 18, held < 1 day -> 0, 24h unknown -> 5, P/L from the basis
        uint8 pl = _plPoints(alice);
        assertEq(gate.factScore(alice, bal / 10), 18 + 5 + pl);
        assertEq(gate.factScore(alice, bal / 5), 11 + 5 + pl);
        assertEq(gate.factScore(alice, bal * 35 / 100), 5 + 5 + pl);
        skip(1 days);
        assertEq(gate.factScore(alice, bal / 10), 18 + 5 + 5 + pl);
        skip(2 days);
        assertEq(gate.factScore(alice, bal / 10), 18 + 9 + 5 + pl);
        skip(4 days);
        assertEq(gate.factScore(alice, bal / 10), 18 + 14 + 5 + pl);
        // a 24h-old checkpoint that is lower than now -> price up -> 9 instead of 5
        imd.mint(bob, 100_000e18);
        buy(bob, 1e18);
        skip(25 hours);
        nextBlock();
        buy(bob, 5_000e18); // pumps the price: alice now in profit (>200%?) and 24h up
        uint8 s = gate.factScore(alice, bal / 10);
        assertEq(s, 18 + 14 + 9 + _plPoints(alice));
        assertLe(s, 55);
    }

    function _plPoints(address who) internal view returns (uint8) {
        (uint256 spent, uint256 held) = hook.costBasis(who);
        uint256 value = held * hook.priceX96() / (1 << 96);
        if (value < spent) return 14;
        uint256 g = (value - spent) * 100 / spent;
        if (g <= 50) return 9;
        if (g <= 200) return 5;
        return 0;
    }

    function test_submitRejectsBadText() public {
        uint256 amt = plea.balanceOf(alice) / 10;
        string[8] memory bad = [
            "",
            "contains [PLEA] marker",
            "contains [/plea marker",
            "tab\there",
            unicode"zero​width",
            "soft\xc2\xadhyphen",
            unicode"bom﻿",
            "trailing newline\n"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(CabalGate.BadPleaText.selector);
            gate.submitSell(amt, bad[i]);
        }
        vm.prank(alice);
        vm.expectRevert(CabalGate.BadPleaText.selector);
        gate.submitSell(amt, string(abi.encodePacked("bidi", hex"e280ae", "override")));
        vm.prank(alice);
        vm.expectRevert(CabalGate.BadPleaText.selector);
        gate.submitSell(amt, string(abi.encodePacked("bad utf8 ", hex"c3")));
        bytes memory long = new bytes(281);
        for (uint256 i; i < 281; ++i) {
            long[i] = "a";
        }
        vm.prank(alice);
        vm.expectRevert(CabalGate.BadPleaText.selector);
        gate.submitSell(amt, string(long));
        // 280 bytes of valid UTF-8 (incl. multibyte) is fine, as are quotes and backslashes (escaped)
        vm.prank(alice);
        uint256 id = gate.submitSell(amt, unicode"Plé \"quoted\" back\\slash ünïcode ✓");
        assertTrue(_contains(gate.question(id), 'Pl\xc3\xa9 \\"quoted\\" back\\\\slash'));
    }

    function test_submitRejectsBadAmounts() public {
        uint256 bal = plea.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        gate.submitSell(bal * 36 / 100, TEXT);
        vm.prank(alice);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        gate.submitSell(0, TEXT);
        imd.mint(alice, 10_000_000e18);
        buy(alice, 200e18);
        assertGt(plea.balanceOf(alice), uint256(2_500_000e18) * 10_000 / 3_500);
        vm.prank(alice);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        gate.submitSell(2_500_001e18, TEXT);
        _submit(alice, 2_500_000e18);
    }

    function test_onePendingPerWallet() public {
        _submit(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(CabalGate.PendingExists.selector);
        gate.submitSell(1e18, TEXT);
    }

    function test_approveExecuteWithinWindowAndCooldown() public {
        uint256 amount = plea.balanceOf(alice) / 10;
        uint256 id = _submit(alice, amount);
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotApproved.selector);
        gate.executeSell(0);
        deliver(id, true);
        skip(7 minutes);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 out = gate.executeSell(1);
        assertGt(out, 0);
        assertEq(imd.balanceOf(alice), imdBefore + out);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        // 4h cooldown after an executed sell
        vm.prank(alice);
        vm.expectRevert();
        gate.submitSell(1e18, TEXT);
        skip(4 hours);
        _submit(alice, 1e18);
    }

    function test_slippageGuard() public {
        uint256 id = _submit(alice, plea.balanceOf(alice) / 10);
        deliver(id, true);
        vm.prank(alice);
        vm.expectRevert();
        gate.executeSell(type(uint256).max);
    }

    function test_lapsedApprovalLetsPleadAgain() public {
        uint256 id = _submit(alice, 1e18);
        deliver(id, true);
        skip(7 minutes + 1);
        vm.prank(alice);
        vm.expectRevert(CabalGate.WindowLapsed.selector);
        gate.executeSell(0);
        uint256 id2 = _submit(alice, 1e18); // clears the lapsed one
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Lapsed));
        assertEq(gate.pendingOf(alice), id2);
    }

    function test_deniedThenAppealOnce() public {
        uint256 id = _submit(alice, 1e18);
        deliver(id, false);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Denied));
        vm.prank(alice);
        vm.expectRevert();
        gate.submitSell(1e18, TEXT); // 4h wait
        vm.prank(alice);
        vm.expectRevert(); // the appeal waits out the same 4h as a new plea
        gate.appeal(id, "I was too brief. Here is my whole heart: I hold, I believe, I need rent.");
        skip(4 hours);
        uint256 retainedBefore = hook.retainedImd();
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 appealId = gate.appeal(id, "I was too brief. Here is my whole heart: I hold, I believe, I need rent.");
        assertEq(imd.balanceOf(alice), imdBefore - 0.85e18);
        assertEq(hook.retainedImd() - retainedBefore, 0.35e18);
        assertEq(imd.balanceOf(address(gate)), 0.5e18 + 0.5e18);
        string memory q = gate.question(appealId);
        assertTrue(_contains(q, "APPEAL"));
        assertTrue(_contains(q, "DENIED"));
        assertTrue(_contains(q, "[PLEA]Dear Cabal"));
        vm.prank(alice);
        vm.expectRevert(CabalGate.AlreadyAppealed.selector);
        gate.appeal(id, "again");
        deliver(appealId, true);
        vm.prank(alice);
        gate.executeSell(0);
        // an appeal cannot itself be appealed
        uint256 id3;
        skip(4 hours);
        id3 = _submit(alice, 1e18);
        deliver(id3, false);
        skip(4 hours);
        vm.prank(alice);
        uint256 a3 = gate.appeal(id3, "please");
        deliver(a3, false);
        vm.prank(alice);
        vm.expectRevert(CabalGate.AlreadyAppealed.selector);
        gate.appeal(a3, "please again");
    }

    function _copy(OracleAttestation.Attestation memory a)
        internal
        pure
        returns (OracleAttestation.Attestation memory)
    {
        return abi.decode(abi.encode(a), (OracleAttestation.Attestation));
    }

    function test_verdictRejectsBadAttestations() public {
        uint256 id = _submit(alice, 1e18);
        OracleAttestation.Attestation memory a = attestationFor(id, true, keccak256("r1"));
        bytes memory sig = sign(a);
        // wrong signer
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, gate.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        gate.deliverVerdict(id, a, abi.encodePacked(r, s, v));
        // tampered answer under the original signature
        OracleAttestation.Attestation memory t = _copy(a);
        t.answer = abi.encode(false);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        gate.deliverVerdict(id, t, sig);
        // wrong question hash
        t = _copy(a);
        t.questionHash = keccak256("other");
        bytes memory s2 = sign(t);
        vm.expectRevert(CabalGate.QuestionMismatch.selector);
        gate.deliverVerdict(id, t, s2);
        // small panel / too few agreed
        t = _copy(a);
        t.panelSize = 5;
        s2 = sign(t);
        vm.expectRevert(CabalGate.WrongPanel.selector);
        gate.deliverVerdict(id, t, s2);
        t = _copy(a);
        t.agreed = 19;
        s2 = sign(t);
        vm.expectRevert(CabalGate.WrongPanel.selector);
        gate.deliverVerdict(id, t, s2);
        // expired
        t = _copy(a);
        t.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        s2 = sign(t);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, t.expiresAt));
        gate.deliverVerdict(id, t, s2);
        // wrong answer type
        t = _copy(a);
        t.answerType = OracleAttestation.ANSWER_UINT256;
        t.answer = abi.encode(uint256(1));
        s2 = sign(t);
        vm.expectRevert();
        gate.deliverVerdict(id, t, s2);
        // the good one, delivered under the 200k stipend, then replayed
        gate.deliverVerdict{gas: 200_000}(id, a, sig);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved));
        vm.expectRevert(CabalGate.NotPending.selector);
        gate.deliverVerdict(id, a, sig);
        uint256 id2 = _submit(bob, 1e18);
        OracleAttestation.Attestation memory b = attestationFor(id2, true, keccak256("r1")); // same requestId
        s2 = sign(b);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, keccak256("r1")));
        gate.deliverVerdict(id2, b, s2);
    }

    function test_cancelUnansweredPlea() public {
        uint256 id = _submit(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotMatured.selector);
        gate.cancel(id);
        skip(3 hours);
        vm.prank(alice);
        gate.cancel(id);
        assertEq(gate.pendingOf(alice), 0);
        _submit(alice, 1e18);
    }

    function test_deadManSwitch() public {
        vm.expectRevert();
        gate.killCabal();
        uint256 id = _submit(alice, 1e18);
        skip(47 hours);
        deliver(id, false); // resets the clock
        skip(47 hours);
        vm.expectRevert();
        gate.killCabal();
        skip(1 hours + 1);
        gate.killCabal();
        assertTrue(plea.cabalDead());
        vm.prank(alice);
        plea.transfer(bob, 1e18);
        // PLEA.killCabal is gate-only
        vm.expectRevert(PLEA.NotGate.selector);
        plea.killCabal();
    }

    function test_ownerPowers() public {
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotOwner.selector);
        gate.withdrawImd(alice, 1);
        _submit(alice, 1e18);
        vm.prank(OWNER);
        gate.withdrawImd(OWNER, 0.5e18);
        assertEq(imd.balanceOf(OWNER), 0.5e18);
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotOwner.selector);
        gate.setSigner(alice);
        vm.prank(OWNER);
        gate.setSigner(ORACLE_SIGNER);
        assertEq(gate.oracleSigner(), ORACLE_SIGNER);
        // PLEA allowlist is owner-only and add-only
        vm.prank(alice);
        vm.expectRevert();
        plea.allow(alice);
        vm.prank(OWNER);
        plea.allow(alice);
        vm.prank(alice);
        plea.transfer(bob, 1e18);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
