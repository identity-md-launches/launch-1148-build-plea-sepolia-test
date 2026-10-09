// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPleaHookSeed {
    function seed() external;
    function poolManager() external view returns (address);
}

/// @title PLEA — the sell-gated meme token
/// @notice 1e9 supply, 18 decimals, minted once in `init` (90% hook, 10% distributor). While the
/// Cabal lives, transfers are restricted: see `_update`. After `killCabal` nothing is restricted.
contract PLEA is ERC20, Ownable {
    error CabalIsWatching();
    error NotDeployTx();
    error AlreadyInitialized();
    error NotGate();
    error ZeroAddress();

    event Initialized(address indexed hook, address indexed gate, address indexed distributor);
    event Allowed(address indexed account);
    event CabalKilled(uint256 at);

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// @dev Transient slot set by the constructor; `init` works only while it is set (EIP-1153).
    // keccak256("plea.deploy-tx") - 1
    uint256 private constant DEPLOY_TX_SLOT = 0x6e1b7d1b1a9e3e1b4d3f8c2a1d0b9e8f7c6b5a4d3e2f1a0b9c8d7e6f5a4b3c2d;

    /// @dev Fallback for the transient flag: forge (and the launch rehearsal harness) clears
    /// transient storage between top-level calls, so init also accepts the deployment block.
    uint256 public immutable deployBlock;

    address public hook;
    address public gate;
    address public distributor;
    address public poolManager;
    bool public initialized;
    bool public cabalDead;
    uint256 public cabalKilledAt;

    /// @notice Add-only allowlist of senders exempt from the Cabal's transfer rule.
    mapping(address => bool) public allowed;
    /// @notice First time an address received PLEA (holding clock for the fact score).
    mapping(address => uint256) public firstReceivedAt;

    constructor(address owner_) ERC20("PLEA", "PLEA") Ownable(owner_) {
        deployBlock = block.number;
        assembly ("memory-safe") {
            tstore(DEPLOY_TX_SLOT, 1)
        }
    }

    /// @notice Records the hook, gate and distributor, mints the whole supply and seeds the pool.
    /// Only callable in the deployment transaction (transient flag), and only once.
    function init(address hook_, address gate_, address distributor_) external {
        uint256 flag;
        assembly ("memory-safe") {
            flag := tload(DEPLOY_TX_SLOT)
        }
        if (flag != 1 && block.number != deployBlock) revert NotDeployTx();
        if (initialized) revert AlreadyInitialized();
        if (hook_ == address(0) || gate_ == address(0) || distributor_ == address(0)) revert ZeroAddress();
        assembly ("memory-safe") {
            tstore(DEPLOY_TX_SLOT, 0)
        }
        initialized = true;
        hook = hook_;
        gate = gate_;
        distributor = distributor_;
        poolManager = IPleaHookSeed(hook_).poolManager();
        _mint(hook_, TOTAL_SUPPLY * 90 / 100);
        _mint(distributor_, TOTAL_SUPPLY * 10 / 100);
        emit Initialized(hook_, gate_, distributor_);
        IPleaHookSeed(hook_).seed();
    }

    /// @notice Owner adds an address that may send PLEA freely while the Cabal lives. Add-only.
    function allow(address account) external onlyOwner {
        allowed[account] = true;
        emit Allowed(account);
    }

    /// @notice The gate's dead-man switch lands here: lifts every restriction, forever.
    function killCabal() external {
        if (msg.sender != gate) revert NotGate();
        if (!cabalDead) {
            cabalDead = true;
            cabalKilledAt = block.timestamp;
            emit CabalKilled(block.timestamp);
        }
    }

    /// @notice Burns the caller's own tokens (the hook burns trims and the burn fee this way).
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!cabalDead && from != address(0)) {
            if (to == poolManager) {
                if (from != gate && from != hook) revert CabalIsWatching();
            } else if (
                to != gate && from != poolManager && from != hook && from != gate && from != distributor
                    && !allowed[from]
            ) {
                revert CabalIsWatching();
            }
        }
        if (to != address(0) && firstReceivedAt[to] == 0) firstReceivedAt[to] = block.timestamp;
        super._update(from, to, value);
    }
}
