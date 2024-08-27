// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FeeLibrary} from "v4-core/libraries/FeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";
import {DynamicFeeStub} from "../src/DynamicFeeStub.sol";

contract DynamicFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    DynamicFeeHook hook = DynamicFeeHook(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

    PoolManager poolManager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;
    TestERC20 token0;
    TestERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager(500_000);
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    function _deployERC20Tokens() private {
        TestERC20 tokenA = new TestERC20(2 ** 128);
        TestERC20 tokenB = new TestERC20(2 ** 128);

        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function _stubValidateHookAddress() private {
        DynamicFeeStub stub = new DynamicFeeStub(poolManager, hook);

        (, bytes32[] memory writes) = vm.accesses(address(stub));

        vm.etch(address(hook), address(stub).code);

        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _initializePool() private {
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000 | FeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_RATIO_1_1, '0x00');
    }

    function _addLiquidityToPool() private {
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 10 ether)
        );

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-120, 120, 10 ether)
        );

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                50 ether
            )
        );

        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    function test_ProperFeeApplicationBasedOnVolatility() public {
        vm.roll(100);

        IPoolManager.SwapParams memory params = _getSwapParams(true, 1 ether);

        uint24 initialFee = hook.getFee(address(this), poolKey, params, "0x00");
        assertEq(initialFee, 3000);

        _swap(params);

        vm.roll(101);
        uint24 feeAfterFirstSwap = hook.getFee(address(this), poolKey, params, "0x00");
        assertEq(feeAfterFirstSwap, 3000);

        _swap(params);

        vm.roll(102);
        uint24 feeAfterVolatility = hook.getFee(address(this), poolKey, params, "0x00");
        assertTrue(feeAfterVolatility > 3000);
    }

    function test_CorrectLiquidityProvisioningAndRemoval() public {
        vm.roll(100);
        _addLiquidityToPool();

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, -5 ether)
        );

        uint256 liquidity = modifyPositionRouter.getPositionLiquidity(poolKey, address(this), -60, 60);
        assertEq(liquidity, 45 ether);

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 5 ether)
        );

        liquidity = modifyPositionRouter.getPositionLiquidity(poolKey, address(this), -60, 60);
        assertEq(liquidity, 50 ether);
    }

    function test_AccurateSlippageProtection() public {
        vm.roll(100);

        IPoolManager.SwapParams memory params = _getSwapParams(true, 1 ether);
        _swap(params);

        vm.roll(101);
        params = _getSwapParams(true, 1 ether);
        _swap(params);

        vm.roll(102);
        params = _getSwapParams(true, 1 ether);
        params.maxSlippage = 500;
        _swap(params);
    }

    function test_EdgeCasesWithDramaticPriceChanges() public {
        vm.roll(100);

        IPoolManager.SwapParams memory params = _getSwapParams(true, 50 ether);
        _swap(params);

        vm.roll(101);
        params = _getSwapParams(false, 50 ether);
        _swap(params);

        vm.roll(102);
        params = _getSwapParams(true, 50 ether);
        _swap(params);

        vm.roll(103);
        params = _getSwapParams(false, 50 ether);
        _swap(params);
    }

    function _swap(IPoolManager.SwapParams memory params) private {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            withdrawTokens: true,
            settleUsingTransfer: true
        });

        swapRouter.swap(poolKey, params, testSettings);
    }

    function _getSwapParams(bool zeroForOne, int256 amountSpecified) private pure returns (IPoolManager.SwapParams memory params) {
        params.zeroForOne = zeroForOne;
        params.amountSpecified = amountSpecified;
        params.sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
    }
}
