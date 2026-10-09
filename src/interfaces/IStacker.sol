// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice imd/acc Stacker: pulls `amount` TestIMD from msg.sender (approved) and credits `to`
/// with sIMD under project = msg.sender. Selector `credit(address,uint256)` is present in the
/// Sepolia Stacker bytecode (0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477).
interface IStacker {
    function credit(address to, uint256 amount) external;
}
