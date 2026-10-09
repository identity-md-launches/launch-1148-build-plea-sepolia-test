// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PleaHook} from "./PleaHook.sol";
import {IStacker} from "./interfaces/IStacker.sol";

interface IPLEAForLaunch {
    function owner() external view returns (address);
    function init(address hook, address gate, address distributor) external;
}

/// @title PleaLaunch — mines a CREATE2 salt on chain, deploys PleaHook at a flagged address and
/// wires PLEA in the same transaction.
/// @dev Deployed last by the launch factory. The whole launch reverts if any step fails.
contract PleaLaunch {
    error SaltNotFound();
    error HookDeployFailed();

    uint256 public constant MAX_TRIES = 100_000;
    uint160 public constant FLAG_MASK = (1 << 14) - 1;

    address public immutable hook;
    uint256 public immutable salt;
    uint256 public immutable tries;

    constructor(address plea, address gate, address distributor, address poolManager, address imd, address stacker) {
        address owner = IPLEAForLaunch(plea).owner();
        bytes memory initCode = abi.encodePacked(
            type(PleaHook).creationCode,
            abi.encode(IPoolManager(poolManager), plea, IERC20(imd), IStacker(stacker), owner)
        );
        uint160 flags = _flags();
        (uint256 s, uint256 n) = mine(address(this), keccak256(initCode), flags);
        salt = s;
        tries = n;
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), s)
        }
        if (deployed == address(0) || uint160(deployed) & FLAG_MASK != flags) revert HookDeployFailed();
        hook = deployed;
        IPLEAForLaunch(plea).init(deployed, gate, distributor);
    }

    function _flags() internal pure returns (uint160) {
        // beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta
        return (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    }

    /// @notice The flag bits PleaHook's address must carry.
    function requiredFlags() external pure returns (uint160) {
        return _flags();
    }

    /// @notice Finds the first salt in 0,1,2,… whose CREATE2 address from `deployer` has exactly
    /// `flags` in its low 14 bits. Fixed memory, no allocation in the loop. Reverts after MAX_TRIES.
    function mine(address deployer, bytes32 initCodeHash, uint160 flags)
        public
        pure
        returns (uint256 found, uint256 count)
    {
        bool ok;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x60))
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 53), initCodeHash)
            for { let s := 0 } lt(s, 100000) { s := add(s, 1) } {
                mstore(add(ptr, 21), s)
                let a := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
                if eq(and(a, 0x3fff), flags) {
                    found := s
                    count := add(s, 1)
                    ok := 1
                    break
                }
            }
        }
        if (!ok) revert SaltNotFound();
    }
}
