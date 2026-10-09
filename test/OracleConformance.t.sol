// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PLEA} from "../src/PLEA.sol";

/// @dev The protocol's conformance vector, with CabalGate as the consumer, plus the live attestation
/// f7af4af1-b840-4649-9135-283a31158847 recovered to the oracle signer.
contract OracleConformanceTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "deliverVerdict(uint256,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    address constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant LIVE_CONSUMER = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;

    CabalGate consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        PLEA plea = new PLEA(address(this));
        deployCodeTo("CabalGate.sol:CabalGate", abi.encode(address(plea), address(0x1234), SIGNER), VECTOR_CONSUMER);
        consumer = CabalGate(VECTOR_CONSUMER);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST, "struct, type string or domain differs");
    }

    function test_callbackSelectorHasTheProtocolStruct() public view {
        assertEq(consumer.deliverVerdict.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function test_protocolSignatureRecoversToVectorSigner() public view {
        bytes32 digest = consumer.attestationDigest(vector());
        (bytes32 r, bytes32 s, uint8 v) = _split(VECTOR_SIGNATURE);
        assertEq(ecrecover(digest, v, r, s), SIGNER);
    }

    /// @notice Live attestation f7af4af1-b840-4649-9135-283a31158847 (api.imd.fun), signed for consumer
    /// 0x37bfb8ac7c960e558657871d41ca70e07e7dbfff on Ethereum, recovers to the oracle signer.
    function test_liveAttestationRecoversToOracleSigner() public {
        vm.chainId(1);
        PLEA plea = new PLEA(address(this));
        deployCodeTo(
            "CabalGate.sol:CabalGate", abi.encode(address(plea), address(0x1234), ORACLE_SIGNER), LIVE_CONSUMER
        );
        CabalGate live = CabalGate(LIVE_CONSUMER);
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: 0xf7af4af1b84046499135283a3115884700000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x39eecf277118e4219d50e4352a2fcf943cf802239c546d54dd4baba53c72d787,
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: hex"00000000000000000000000000000000000000000000000000000000d58e9650",
            figure: 3582891600,
            fromBlock: 26122900,
            toBlock: 26122901,
            blockHash: 0x22cd78830715d67d27849123a084fe3b854a1af74b40cd7f73c727399eef3059,
            panelJobId: 0xdb171fe4285c42d98927e5159ae7632d00000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 4,
            issuedAt: 1791446260,
            expiresAt: 1791467860
        });
        bytes memory sig =
            hex"fc6d1206c4c9abff8cdd27204ddd1e186d0eeb960de1af1c8af49584ac178de71c18e894324ffe38c8c12d1b4340e32634ffe61734e941d0889d42b9921443761c";
        (bytes32 r, bytes32 s, uint8 v) = _split(sig);
        assertEq(ecrecover(live.attestationDigest(a), v, r, s), ORACLE_SIGNER, "live attestation signer");
    }

    function _split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }
}
