// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";

import "./interfaces/IBorrowable.sol";
import "./interfaces/IRouter.sol";


contract StrategyImperamaxLender is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    uint256 private constant BASIS_PRECISION = 10000;
    uint256 internal constant BTOKEN_DECIMALS = 1e18;
    uint256 internal WANT_PRECISION;
    
    bool public reorder = true;
    
    IRouter constant router = IRouter(0x283e62CFe14b352dB8e30A9575481DCbf589Ad98);

    //This records the current pools and allocations
    address[] public pools;
    bool[] public preventDeposits; // use this if we want to shut down a pool
    
    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us

    string internal stratName; // set our strategy name here

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, address[] memory _pools, string memory _name) public BaseStrategy(_vault) {
        _initializeStrat(_pools, _name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    function _initializeStrat(address[] memory _pools, string memory _name) internal {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 2 days;

        // set up our pools
        manuallySetOrder(_pools);
        
        // set our want token precision since bTokens use this for supplied and borrowed
        WANT_PRECISION = 10 ** vault.decimals();
        
        for (uint256 i = 0; i < _pools.length; i++) {
            want.approve(_pools[i], type(uint256).max);
            preventDeposits.push(false);
        }

        // set our strategy's name
        stratName = _name;
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address[] memory _pools, 
        string memory _name
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_pools, _name);
    }

    function cloneStrategy(address _vault, address[] memory _pools, string memory _name) external returns (address newStrategy) {
        newStrategy = this.cloneStrategy(_vault, msg.sender, msg.sender, msg.sender, _pools, _name);
    }

    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address[] memory _pools, 
        string memory _name
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategyImperamaxLender(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _pools, _name);

        emit Cloned(newStrategy);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    /// @notice Returns value of native want tokens held in the strategy.
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }
 
 
    // need to figure this out better
    /// @notice Returns value of want lent, held in the form of bTokens.
    function stakedBalance() public view returns (uint256 total) {
        total = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            address currentPool = pools[i];
            
            uint256 bTokenBalance = IBorrowable(currentPool).balanceOf(address(this));
            uint256 currentExchangeRate = IBorrowable(currentPool).exchangeRateLast();
            total = total.add(bTokenBalance.mul(currentExchangeRate).div(BTOKEN_DECIMALS));
        }
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the want balance and staked balance
        return balanceOfWant().add(stakedBalance());
    }

    function getEachPoolUtilization() internal view returns (uint256[] memory utilization) {
        utilization = new uint256[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            address currentPool = pools[i];
            
            uint256 totalSupplied = IBorrowable(currentPool).totalSupply();
            uint256 totalBorrows = IBorrowable(currentPool).totalBorrows();
            utilization[i] = totalSupplied.mul(WANT_PRECISION).div(totalBorrows);
        }
    }
    
    // a more precise way to do this might be to convert the fraction of bTokens we have to the total supply, and then convert that by the total amount of underlying supplied
    function wantSuppliedToPool(address _pool) internal view returns (uint256 wantBal) {
        uint256 bTokenBalance = IBorrowable(_pool).balanceOf(address(this));
        uint256 currentExchangeRate = IBorrowable(_pool).exchangeRateLast();
        wantBal = bTokenBalance.mul(currentExchangeRate).div(BTOKEN_DECIMALS);
    }
    
    /// @notice Reorder our array of pools by increasing utilization. Deposits go to the last pool, withdrawals start from the front.
    function reorderPools() public onlyEmergencyAuthorized {
        uint256[] memory utilizations = getEachPoolUtilization();
        address[] memory newPoolSorting = pools;
        if (utilizations.length > 1) {
            _reorderPools(utilizations, newPoolSorting, 0, utilizations.length - 1);
        }
        pools = newPoolSorting;
    }

    function _reorderPools(
        uint256[] memory utilizations,
        address[] memory newPoolSorting,
        uint256 low,
        uint256 high
    ) internal pure {
        if (low < high) {
            uint256 pivotVal = utilizations[(low + high) / 2];

            uint256 low1 = low;
            uint256 high1 = high;
            for (;;) {
                while (utilizations[low1] < pivotVal) low1++;
                while (utilizations[high1] > pivotVal) high1--;
                if (low1 >= high1) break;
                (utilizations[low1], utilizations[high1]) = (utilizations[high1], utilizations[low1]);
                (newPoolSorting[low1], newPoolSorting[high1]) = (newPoolSorting[high1], newPoolSorting[low1]);
                low1++;
                high1--;
            }
            if (low < high1) _reorderPools(utilizations, newPoolSorting, low, high1);
            high1++;
            if (high1 < high) _reorderPools(utilizations, newPoolSorting, high1, high);
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
        
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // before we start withdrawing or taking any profit, we should update our exchange rates
        updateExchangeRates();
        
        // update our order of our pools
        if (reorder) {
            reorderPools();
        }
        
        // debtOustanding will only be > 0 if we need to rebalance from a withdrawal or lowering the debtRatio, or if we revoke the strategy.
        uint256 stakedBal = stakedBalance();
        if (_debtOutstanding > 0) {
            if (stakedBal > 0) {
                // don't bother withdrawing if we don't have staked funds
                _withdraw(Math.min(stakedBal, _debtOutstanding));
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // this is where we record our profit and (hopefully no) losses
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets.sub(debt);
            
            // we need to prove to the vault that we have enough want to cover our profit and debt payment
            uint256 _wantBal = balanceOfWant();
            uint256 amountToFree = _profit.add(_debtPayment).sub(_wantBal);
            
            // use this only for debugging
            emit Withdrawn(amountToFree);
            // use this only for debugging
            
            _withdraw(amountToFree);
        }
        // if assets are less than debt, we are in trouble. Losses should never happen, but if it does, let's record it accurately.
        else {
            _loss = debt.sub(assets);
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }
    
    // use this only for debugging
    event Withdrawn(uint256 toWithdraw); 
    // use this only for debugging

    function updateExchangeRates() internal {
        //Update all the rates before harvest or withdrawals
        for (uint256 i = 0; i < pools.length; i++) {
            IBorrowable(pools[i]).exchangeRate();
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        
        uint256 toInvest = balanceOfWant();
        if (toInvest > 0) {
            _deposit(toInvest);
        }
    }

    function _deposit(uint256 _depositAmount) internal {
        //Deposit to highest utilization pair, which should be last in our pools array
        for (uint256 i = pools.length.sub(1); i >= 0; i--) {
            if (!preventDeposits[i]) { // only deposit to this pool if it's not shutting down.
                if (_depositAmount > 0) {
                    address targetPool = pools[i];
                    want.transfer(targetPool, _depositAmount);
                    require(IBorrowable(targetPool).mint(address(this)) >= 0, "No lend tokens minted");
                }
                break;
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBal = balanceOfWant();
        if (_amountNeeded > _wantBal) {
            // check if we have enough free funds to cover the withdrawal
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                uint256 amountToWithdraw = (Math.min(_stakedBal, _amountNeeded.sub(_wantBal)));
                _withdraw(amountToWithdraw);
            }
            uint256 _withdrawnBal = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBal);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    function _withdraw(uint256 _amountToWithdraw) internal {
        // Update our rates before trying to withdraw
        updateExchangeRates();
        
        // keep track of how much we need to withdraw
        uint256 remainingUnderlyingNeeded = _amountToWithdraw;
        uint256 withdrawn;

        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            address currentPool = pools[i];
        
            // how much want our strategy has supplied to this pool
            uint256 suppliedToPool = wantSuppliedToPool(currentPool);
            
            // total liquidity available in the pool in want
            uint256 PoolLiquidity = want.balanceOf(currentPool);
            
            // the minimum of the previous two values is the most want we can withdraw from this pool
            uint256 ableToPullInUnderlying = Math.min(suppliedToPool, PoolLiquidity);
            
            // skip ahead to our next loop if we can't withdraw anything
            if (ableToPullInUnderlying == 0) {
                continue;
            }
            
            // get our exchange rate for this pool of bToken to want
            uint256 currentExchangeRate = IBorrowable(currentPool).exchangeRateLast();
            
            // figure out how much bToken we are able to burn from this pool for want
            uint256 ableToPullInbToken = ableToPullInUnderlying.mul(BTOKEN_DECIMALS).div(currentExchangeRate);
            
            // this is how much we need, converted to the bTokens of this specific pool. add 5 wei as a buffer for calculation losses.
            uint256 remainingbTokenNeeded = remainingUnderlyingNeeded.mul(BTOKEN_DECIMALS).div(currentExchangeRate).add(5);

            // Withdraw all we need from the current pool if we can
            if (ableToPullInbToken > remainingbTokenNeeded && remainingbTokenNeeded > 0) {
                IBorrowable(currentPool).transfer(currentPool, remainingbTokenNeeded);
                uint256 pulled = IBorrowable(currentPool).redeem(address(this));
                
                // add what we just withdrew to our total
                withdrawn = withdrawn.add(pulled);
                break;
            }
            //Otherwise withdraw what we can from current pool
            else {
                IBorrowable(currentPool).transfer(currentPool, ableToPullInbToken);
                uint256 pulled = IBorrowable(currentPool).redeem(address(this));
                
                // add what we just withdrew to our total, subtract it from what we still need
                withdrawn = withdrawn.add(pulled);
                remainingUnderlyingNeeded = remainingUnderlyingNeeded.sub(pulled);
            }
        }
        require(withdrawn >= _amountToWithdraw, "Low liquidity");
    }

    function liquidateAllPositions() internal virtual override returns (uint256 _liquidatedAmount) {
        _withdrawMaxPossible(); // this will withdraw the maximum we can based on free liquidity
        _liquidatedAmount = balanceOfWant();
    }

    /// @notice Withdraw the maximum liquidity we can from all pools. Only to be called in emergency situations.
    function _withdrawMaxPossible() public onlyEmergencyAuthorized {
        //Update our rates before trying to withdraw
        updateExchangeRates();

        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            address currentPool = pools[i];
            
            // how much want our strategy has supplied to this pool
            uint256 suppliedToPool = wantSuppliedToPool(currentPool);
            
            // total liquidity available in the pool in want
            uint256 PoolLiquidity = want.balanceOf(currentPool);
            
            // the minimum of the previous two values is the most want we can withdraw from this pool
            uint256 ableToPullInUnderlying = Math.min(suppliedToPool, PoolLiquidity);
            
            // get our exchange rate for this pool of bToken to want
            uint256 currentExchangeRate = IBorrowable(currentPool).exchangeRateLast();
            
            // figure out how much bToken we are able to burn from this pool for want
            uint256 ableToPullInbToken = ableToPullInUnderlying.mul(BTOKEN_DECIMALS).div(currentExchangeRate);
            
            // redeem our whole bToken balance if there is enough liquidity in the pool so we don't have dust leftover
            if (PoolLiquidity > suppliedToPool) {
                // burn all of our bToken
                uint256 balanceOfbToken = IBorrowable(currentPool).balanceOf(address(this));
                if (balanceOfbToken > 0) {
                    IBorrowable(currentPool).transfer(currentPool, balanceOfbToken);
                    IBorrowable(currentPool).redeem(address(this));
                }
                require(IBorrowable(currentPool).balanceOf(address(this)) == 0, "Tokens left");
            } else if (ableToPullInbToken > 0) { // pull out as much as we can from this pool
                IBorrowable(currentPool).transfer(currentPool, ableToPullInbToken);
                IBorrowable(currentPool).redeem(address(this));
            }
        }
    }


//     function manuallySetAllocations(uint256[] calldata _ratios)
//         external
//         onlyAuthorized
//     {
//         // length of ratios must match number of pairs
//         require(_ratios.length == pools.length);
// 
//         uint256 totalRatio;
// 
//         for (uint256 i = 0; i < kashiPairs.length; i++) {
//             // We must accrue all pairs to ensure we get an accurate estimate of assets
//             accrueInterest(kashiPairs[i].kashiPair);
//             totalRatio += _ratios[i];
//         }
// 
//         require(totalRatio == MAX_BPS); //ratios must add to 10000 bps
// 
//         uint256 wantBalance = balanceOfWant();
//         if (wantBalance > dustThreshold) {
//             depositInBento(wantBalance);
//         }
// 
//         uint256 totalAssets = estimatedTotalAssets();
//         uint256[] memory kashiPairsIncreasedAllocation =
//             new uint256[](kashiPairs.length);
// 
//         for (uint256 i = 0; i < kashiPairs.length; i++) {
//             KashiPairInfo memory kashiPairInfo = kashiPairs[i];
// 
//             uint256 pairTotalAssets =
//                 bentoSharesToWant(
//                     kashiFractionToBentoShares(
//                         kashiPairInfo.kashiPair,
//                         kashiFractionTotal(
//                             kashiPairInfo.kashiPair,
//                             kashiPairInfo.pid
//                         )
//                     )
//                 );
//             uint256 targetAssets = (_ratios[i] * totalAssets) / MAX_BPS;
//             if (targetAssets < pairTotalAssets) {
//                 uint256 toLiquidate = pairTotalAssets.sub(targetAssets);
//                 liquidateKashiPair(
//                     kashiPairInfo.kashiPair,
//                     kashiPairInfo.pid,
//                     wantToBentoShares(toLiquidate)
//                 );
//             } else if (targetAssets > pairTotalAssets) {
//                 kashiPairsIncreasedAllocation[i] = targetAssets.sub(
//                     pairTotalAssets
//                 );
//             }
//         }
// 
//         for (uint256 i = 0; i < kashiPairs.length; i++) {
//             if (kashiPairsIncreasedAllocation[i] == 0) continue;
// 
//             KashiPairInfo memory kashiPairInfo = kashiPairs[i];
// 
//             uint256 sharesInBento = sharesInBento();
//             uint256 sharesToAdd =
//                 wantToBentoShares(kashiPairsIncreasedAllocation[i]);
// 
//             if (sharesToAdd > sharesInBento) {
//                 sharesToAdd = sharesInBento;
//             }
// 
//             depositInKashiPair(
//                 kashiPairInfo.kashiPair,
//                 kashiPairInfo.pid,
//                 sharesToAdd
//             );
//         }
//     }
// 
//     function addKashiPair(address _newKashiPair, uint256 _newPid)
//         external
//         onlyGovernance
//     {
//         // cannot exceed max pair length
//         require(kashiPairs.length < MAX_PAIRS);
//         // must use the correct bentobox
//         require(
//             address(IKashiPair(_newKashiPair).bentoBox()) == address(bentoBox)
//         );
//         // kashPair asset must match want
//         require(IKashiPair(_newKashiPair).asset() == BIERC20(address(want)));
//         if (_newPid != 0) {
//             // masterChef pid token must match the kashiPair
//             require(
//                 address(masterChef.poolInfo(_newPid).lpToken) == _newKashiPair
//             );
//         }
// 
//         for (uint256 i = 0; i < kashiPairs.length; i++) {
//             // kashiPair must not already be attached
//             require(_newKashiPair != address(kashiPairs[i].kashiPair));
//         }
// 
//         kashiPairs.push(KashiPairInfo(IKashiPair(_newKashiPair), _newPid));
// 
//         if (_newPid != 0) {
//             IERC20(_newKashiPair).safeApprove(
//                 address(masterChef),
//                 type(uint256).max
//             );
//         }
//     }
// 
//     function removeKashiPair(
//         address _remKashiPair,
//         uint256 _remIndex,
//         bool _force
//     ) external onlyEmergencyAuthorized {
//         KashiPairInfo memory kashiPairInfo = kashiPairs[_remIndex];
// 
//         require(_remKashiPair == address(kashiPairInfo.kashiPair));
// 
//         liquidateKashiPair(
//             kashiPairInfo.kashiPair,
//             kashiPairInfo.pid,
//             type(uint256).max // liquidateAll
//         );
// 
//         if (!_force) {
//             // must have liquidated all but dust
//             require(
//                 kashiFractionTotal(
//                     kashiPairInfo.kashiPair,
//                     kashiPairInfo.pid
//                 ) <= dustThreshold
//             );
//         }
// 
//         if (kashiPairInfo.pid != 0) {
//             IERC20(_remKashiPair).safeApprove(address(masterChef), 0);
//         }
//         kashiPairs[_remIndex] = kashiPairs[kashiPairs.length - 1];
//         kashiPairs.pop();
//     }

    // add an event when a pool is removed successfully?
    
    // TAROT DEFINITELY MAKES DECIMALS LINE UP!!!!!!!! So the smallest unit for a USDC one is at the 6 decimals, so 6e-18 bToken = 6e-6 USDC. uses floor though!!!!!

    /// @notice This is used for shutting down lending to a particular pool gracefully. May need to be called more than once for a given pool.
    function attemptToRemovePool(address _poolToRemove, address[] memory _newPools) external onlyEmergencyAuthorized {
        // amount strategy has supplied to this pool
        uint256 suppliedToPool = wantSuppliedToPool(_poolToRemove);
        
        // total liquidity available in the pool in want
        uint256 PoolLiquidity = want.balanceOf(_poolToRemove);
        
        // get our exchange rate for this pool of bToken to want
        uint256 currentExchangeRate = IBorrowable(_poolToRemove).exchangeRateLast();
            
        // use a helper pool to keep track of multiple pools that are being shutdown.
        bool[] memory helperPool = preventDeposits;
        delete preventDeposits; // this is now all false
        
        // Check if there is enough liquidity to withdraw our whole position immediately
        if (PoolLiquidity > suppliedToPool) {
            // burn all of our bToken
            uint256 balanceOfbToken = IBorrowable(_poolToRemove).balanceOf(address(this));
            if (balanceOfbToken > 0) {
                IBorrowable(_poolToRemove).transfer(_poolToRemove, balanceOfbToken);
                IBorrowable(_poolToRemove).redeem(address(this));
            }
            require(IBorrowable(_poolToRemove).balanceOf(address(this)) == 0, "Tokens left");
            
            // we can now remove this pool from our array
            for (uint256 i = 0; i < helperPool.length; i++) {
                if (!helperPool[i])  {
                    // these are normal pools that allow deposits
                    preventDeposits.push(false);
                } else if (helperPool[i] && pools[i] != _poolToRemove) {
                    // this allows us to be emptying multiple pools at once. if the pool is emptying but not the one we're removing, leave it alone.
                    preventDeposits.push(true);
                }
            }
        } else { // Otherwise withdraw what we can from current pool
            // the most want we can withdraw from this pool
            uint256 ableToPullInUnderlying = Math.min(suppliedToPool, PoolLiquidity);
            
            // convert that to bToken and redeem (withdraw)
            uint256 ableToPullInbToken = ableToPullInUnderlying.mul(BTOKEN_DECIMALS).div(currentExchangeRate);
            if (ableToPullInbToken > 0) {
                IBorrowable(_poolToRemove).transfer(_poolToRemove, ableToPullInbToken);
                IBorrowable(_poolToRemove).redeem(address(this));
            }
            
            // we can now remove this pool from our array
            for (uint256 i = 0; i < helperPool.length; i++) {
                if (pools[i] ==_poolToRemove)  {
                    // this is our pool we are targeting
                    preventDeposits.push(true);
                } else if (!helperPool[i]) {
                    // these are normal pools that allow deposits
                    preventDeposits.push(false);
                } else if (helperPool[i] && pools[i] != _poolToRemove) {
                    // this allows us to be emptying multiple pools at once. if the pool is emptying but not the one we're removing, leave it alone.
                    preventDeposits.push(true);
                }
            }
        }

    }

    function manuallySetOrder(address[] memory _poolOrder) public onlyEmergencyAuthorized {
        //Delete old entries and overwrite with new ones
        delete pools;
        for (uint256 i = 0; i < _poolOrder.length; i++) {
            pools.push(_poolOrder[i]);
        }
    }

    // make sure this can handle losses properly! since we may get funds stuck from utilization on migration.
    // can we just transfer the bTokens?
    function prepareMigration(address _newStrategy) internal override {
        liquidateAllPositions();
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }


    /* ========== KEEP3RS ========== */

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }


    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {}

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    function protectedTokens() internal view override returns (address[] memory) {}
}
