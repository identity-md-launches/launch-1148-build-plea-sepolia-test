// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title PleaDistributor — Merkle claim of the 10% distributor share
/// @notice The owner sets the root once. Leaves are keccak256(abi.encodePacked(index, account, amount)).
contract PleaDistributor is Ownable {
    using SafeERC20 for IERC20;

    error RootAlreadySet();
    error RootNotSet();
    error AlreadyClaimed();
    error InvalidProof();

    event RootSet(bytes32 root);
    event Claimed(uint256 indexed index, address indexed account, uint256 amount);

    IERC20 public immutable plea;
    bytes32 public merkleRoot;
    mapping(uint256 => uint256) private claimedBitmap;

    constructor(address plea_, address owner_) Ownable(owner_) {
        plea = IERC20(plea_);
    }

    function setMerkleRoot(bytes32 root) external onlyOwner {
        if (merkleRoot != bytes32(0)) revert RootAlreadySet();
        merkleRoot = root;
        emit RootSet(root);
    }

    function isClaimed(uint256 index) public view returns (bool) {
        return (claimedBitmap[index >> 8] >> (index & 0xff)) & 1 == 1;
    }

    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (merkleRoot == bytes32(0)) revert RootNotSet();
        if (isClaimed(index)) revert AlreadyClaimed();
        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf)) revert InvalidProof();
        claimedBitmap[index >> 8] |= 1 << (index & 0xff);
        emit Claimed(index, account, amount);
        plea.safeTransfer(account, amount);
    }
}
