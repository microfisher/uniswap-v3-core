// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;


import "hardhat/console.sol";

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';


interface IERC20 {

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint);

    function balanceOf(address owner) external view returns (uint);

    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(address from, address to, uint value) external returns (bool);
}

contract Uniswap3 {

    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];


    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }
    

    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    

    struct SwapCache {
        // the protocol fee for the input token
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // the timestamp of the current block
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    constructor() {
        
    }


    function swap(
        address poolAddress,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {

        Slot0 memory slot0Start;
        { 
            IUniswapV3PoolState poolState = IUniswapV3PoolState(poolAddress);
            
            (uint160 sqrtPriceX96,
                int24 tick,
                uint16 observationIndex,
                uint16 observationCardinality,
                uint16 observationCardinalityNext,
                uint8 feeProtocol,
                bool unlocked) = poolState.slot0();

            slot0Start = Slot0(sqrtPriceX96,tick,observationIndex,observationCardinality,observationCardinalityNext,feeProtocol,unlocked);
        }


        SwapCache memory cache =
            SwapCache({
                liquidityStart: uint128(IUniswapV3PoolState(poolAddress).liquidity()),
                blockTimestamp: uint32(block.timestamp),
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
                secondsPerLiquidityCumulativeX128: 0,
                tickCumulative: 0,
                computedLatestObservation: false
            });

        bool exactInput = amountSpecified > 0;

        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: amountSpecified,
                amountCalculated: 0,
                sqrtPriceX96: slot0Start.sqrtPriceX96,
                tick: slot0Start.tick,
                feeGrowthGlobalX128: zeroForOne ?  IUniswapV3PoolState(poolAddress).feeGrowthGlobal0X128() : IUniswapV3PoolState(poolAddress).feeGrowthGlobal1X128(),
                protocolFee: 0,
                liquidity: cache.liquidityStart
            });

            sqrtPriceLimitX96 = (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1);

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            (step.tickNext, step.initialized) = TickBitmap.getNextInitializedTickWithinOneWord(
                poolAddress,
                state.tick,
                IUniswapV3PoolImmutables(poolAddress).tickSpacing(),
                zeroForOne
            );

            // console.log("Current Tick==================");
            // console.logInt(state.tick);

            if (step.initialized) {
  
            }

            //   console.log("\n------------------------START---------------------------");
            //     console.log("========NextTick===========");
            //     console.logInt(step.tickNext);
            //     console.log("========Remaining======");
            //     console.logInt(state.amountSpecifiedRemaining);
            //     console.log("========sqrtPriceX96===");
            //     console.log(state.sqrtPriceX96);
            //     console.log("========liquidity======");
            //     console.log(state.liquidity);
            //     console.log("-------------------------STOP--------------------------\n");

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            uint24 fee = IUniswapV3PoolImmutables(poolAddress).fee();
            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // update global fee tracker
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    // if (!cache.computedLatestObservation) {
                    //     (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                    //         cache.blockTimestamp,
                    //         0,
                    //         slot0Start.tick,
                    //         slot0Start.observationIndex,
                    //         cache.liquidityStart,
                    //         slot0Start.observationCardinality
                    //     );
                    //     cache.computedLatestObservation = true;
                    // }
                    int128 liquidityNet =
                        Tick.getCross(
                            poolAddress,
                            step.tickNext
                        );

                    console.log("==========liquidityNet==========");
                    console.logInt(liquidityNet);

                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // update tick and write an oracle entry if the tick change
        // if (state.tick != slot0Start.tick) {
        //     // (uint16 observationIndex, uint16 observationCardinality) =
        //     //     observations.write(
        //     //         slot0Start.observationIndex,
        //     //         cache.blockTimestamp,
        //     //         slot0Start.tick,
        //     //         cache.liquidityStart,
        //     //         slot0Start.observationCardinality,
        //     //         slot0Start.observationCardinalityNext
        //     //     );
        //     // (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
        //     //     state.sqrtPriceX96,
        //     //     state.tick,
        //     //     observationIndex,
        //     //     observationCardinality
        //     // );
        //     slot0.sqrtPriceX96 = state.sqrtPriceX96;
        //     slot0.tick = state.tick;
        // } else {
        //     // otherwise just update the price
        //     slot0.sqrtPriceX96 = state.sqrtPriceX96;
        // }

        // update liquidity if it changed
        // if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        // if (zeroForOne) {
        //     feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        //     //if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        // } else {
        //     feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        //     //if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        // }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        address token0 = IUniswapV3PoolImmutables(poolAddress).token0();
        address token1 = IUniswapV3PoolImmutables(poolAddress).token1();
        // do the transfers and collect payment
        if (zeroForOne) {
            //if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));
            console.log("Last Tick==================");
            console.logInt(state.tick);
            //uint256 balance0Before = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4).balanceOf(poolAddress);
            console.log("token0-token1==================");
            console.logInt(amount0);
            console.logInt(amount1);
            //IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            //require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            //if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));
            console.log("Tick==================");
            console.logInt(state.tick);
            //uint256 balance1Before = IERC20(0x5300000000000000000000000000000000000004).balanceOf(poolAddress);
            console.log("token1-token0==================");
            console.logInt(amount0);
            console.logInt(amount1);
            //IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            //require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        emit Swap(msg.sender, poolAddress, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        // slot0.unlocked = true;
    }

}