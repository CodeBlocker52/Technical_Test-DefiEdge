// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IDynamicFeeManager} from "v4-core/interfaces/IDynamicFeeManager.sol";
import {FeeLibrary} from "v4-core/libraries/FeeLibrary.sol";

contract DynamicFeeHook is BaseHook, IDynamicFeeManager {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    error MustUseDynamicFee();
    error SlippageExceeded();

    // Store updated tick per block number
    mapping(PoolId => mapping(uint256 => uint24)) public ticksPerBlock;
    mapping(PoolId => mapping(uint256 => uint24)) public dynamicFees;
    



    constructor(IPoolManager _poolManager) BaseHook(_poolManager) IDynamicFeeManager() {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function beforeInitialize(
        address, 
        PoolKey calldata key, 
        uint160, 
        bytes calldata
    ) external pure override returns (bytes4) {
        if (!key.fee) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function beforeSwap(
        address, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata params, 
        bytes calldata 
    ) external override poolManagerOnly returns (bytes4) {
        // Calculate slippage tolerance
        uint24 currentTick = ticksPerBlock[key.toId()][block.number - 1];
        uint24 previousTick = ticksPerBlock[key.toId()][block.number - 2];
        
        uint256 priceImpact = _calculatePriceImpact(currentTick, previousTick);
        if (priceImpact > params.maxSlippage) revert SlippageExceeded();
        
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(
        address, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata, 
        bytes calldata
    ) external  poolManagerOnly returns (bytes4) {
        (, int24 currentTick, , , ,) = poolManager.getSlot0(key.toId());
        _setTick(key.toId(), uint24(currentTick));
        
        _adjustFeeBasedOnVolatility(key);

        return BaseHook.afterSwap.selector;
    }

    function _calculatePriceImpact(uint24 currentTick, uint24 previousTick) private pure returns (uint256) {
        if (previousTick == 0) return 0;
        uint256 priceDifference = currentTick > previousTick ? currentTick - previousTick : previousTick - currentTick;
        return priceDifference.mulDiv(100, previousTick);
    }

    function _adjustFeeBasedOnVolatility(PoolKey calldata key) private {
        PoolId poolId = key.toId();
        uint24 currentTick = ticksPerBlock[poolId][block.number];
        uint24 previousTick = ticksPerBlock[poolId][block.number - 1];

        if (previousTick != 0) {
            uint24 feeDelta = uint24(_calculatePriceImpact(currentTick, previousTick) / 100); // Adjust fee based on volatility
            uint24 baseFee = _revertDynamicFeeFlag(key.fee);
            dynamicFees[poolId][block.number] = baseFee + feeDelta;
        } else {
            dynamicFees[poolId][block.number] = _revertDynamicFeeFlag(key.fee);
        }
    }

    function getFee(
        address, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata, 
        bytes calldata
    ) external view override returns (uint24) {
        return dynamicFees[key.toId()][block.number];
    }

    function _setTick(PoolId poolId, uint24 tick) internal {
        ticksPerBlock[poolId][block.number] = tick;
    }

    function _revertDynamicFeeFlag(uint24 fee) private pure returns (uint24) {
        return fee & ~FeeLibrary.DYNAMIC_FEE_FLAG;
    }
}
