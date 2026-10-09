// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PleaHook} from "../../src/PleaHook.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("TestIMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stacked IMD: records the project a credit came from.
contract MockSIMD is ERC20 {
    bool public paused;
    mapping(address => mapping(address => uint256)) public byProject;

    constructor() ERC20("TestSIMD", "sIMD") {}

    function setPaused(bool p) external {
        paused = p;
    }

    function mintFor(address to, uint256 amount, address project) external {
        require(!paused, "sIMD paused");
        byProject[to][project] += amount;
        _mint(to, amount);
    }
}

/// @dev imd/acc Stacker: pulls IMD from the caller and credits sIMD under project = caller.
contract MockStacker {
    IERC20 public imd;
    MockSIMD public simd;
    bool public burnAllGas;
    uint256 public padGas;

    constructor(IERC20 imd_, MockSIMD simd_) {
        imd = imd_;
        simd = simd_;
    }

    function setBurnAllGas(bool b) external {
        burnAllGas = b;
    }

    function setPadGas(uint256 g) external {
        padGas = g;
    }

    function credit(address to, uint256 amount) external {
        if (burnAllGas) {
            assembly {
                invalid()
            }
        }
        uint256 target = gasleft() > padGas ? gasleft() - padGas : 0;
        while (gasleft() > target) {}
        imd.transferFrom(msg.sender, address(this), amount);
        simd.mintFor(to, amount, msg.sender);
    }
}

/// @dev A plain v4 router: buys (and attempts sells) against the hook's pool.
contract BuyRouter {
    IPoolManager public pm;
    PleaHook public hook;
    IERC20 public imd;
    IERC20 public plea;

    constructor(IPoolManager pm_, PleaHook hook_, IERC20 imd_, IERC20 plea_) {
        pm = pm_;
        hook = hook_;
        imd = imd_;
        plea = plea_;
    }

    function buyExactIn(uint256 imdIn, bytes memory hookData) external returns (uint256 pleaOut) {
        return abi.decode(pm.unlock(abi.encode(msg.sender, true, -int256(imdIn), hookData)), (uint256));
    }

    function buyExactOut(uint256 pleaWanted, bytes memory hookData) external returns (uint256 imdIn) {
        return abi.decode(pm.unlock(abi.encode(msg.sender, true, int256(pleaWanted), hookData)), (uint256));
    }

    function sellExactIn(uint256 pleaIn, bytes memory hookData) external returns (uint256 imdOut) {
        return abi.decode(pm.unlock(abi.encode(msg.sender, false, -int256(pleaIn), hookData)), (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (address payer, bool buy, int256 amountSpecified, bytes memory hookData) =
            abi.decode(raw, (address, bool, int256, bytes));
        PoolKey memory key = hook.poolKey();
        bool pleaIsZero = hook.pleaIsZero();
        bool zeroForOne = buy ? !pleaIsZero : pleaIsZero;
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
        (int128 pleaDelta, int128 imdDelta) = pleaIsZero ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        (IERC20 tokenIn, int128 inDelta, IERC20 tokenOut, int128 outDelta) =
            buy ? (imd, imdDelta, plea, pleaDelta) : (plea, pleaDelta, imd, imdDelta);
        uint256 amountIn = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));
        pm.sync(Currency.wrap(address(tokenIn)));
        tokenIn.transferFrom(payer, address(pm), amountIn);
        pm.settle();
        pm.take(Currency.wrap(address(tokenOut)), payer, amountOut);
        return abi.encode(buy ? (amountSpecified < 0 ? amountOut : amountIn) : amountOut);
    }
}
