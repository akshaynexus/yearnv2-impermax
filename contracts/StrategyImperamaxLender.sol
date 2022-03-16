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

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import "./interfaces/IBorrowable.sol";

interface vaultAPIExtended {
    function emergencyShutdown() external view returns (bool);
}

/*
Things I still need to add
- manual allocation of funds
- more tests for when funds are high utilization and we can't get all out
- look over all comments here to make sure I didn't miss anything: https://github.com/yearn/yearn-strategies/issues/142
*/

contract StrategyImperamaxLender is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    uint256 private constant BASIS_PRECISION = 10000;
    uint256 internal constant BTOKEN_DECIMALS = 1e18;

    bool public reorder = true;

    //This records the current pools and allocations
    address[] public pools;
    bool[] public preventDeposits; // use this if we want to shut down a pool

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us

    string internal stratName; // set our strategy name here

    // check for cloning
    bool internal isOriginal = true;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, string memory _name) public BaseStrategy(_vault) {
        _initializeStrat(_name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    function _initializeStrat(string memory _name) internal {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 2 days;

        // set our strategy's name
        stratName = _name;
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        string memory _name
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_name);
    }

    function cloneTarotLender(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        string memory _name
    ) external returns (address newStrategy) {
        require(isOriginal);

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

        StrategyImperamaxLender(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _name);

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

    /// @notice Returns value of want lent, held in the form of bTokens.
    function stakedBalance() public view returns (uint256 total) {
        total = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            address currentPool = pools[i];

            uint256 bTokenBalance = IBorrowable(currentPool).balanceOf(address(this));
            // uint256 currentExchangeRate = trueExchangeRate(currentPool);
            uint256 currentExchangeRate = IBorrowable(currentPool).exchangeRateLast(); // <- this is the "correct" code using tarot's values
            total = total.add(bTokenBalance.mul(currentExchangeRate).div(BTOKEN_DECIMALS));
        }
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the want balance and staked balance
        return balanceOfWant().add(stakedBalance());
    }

    /// @notice This returns the utilization (borrowed / total deposited) of each of our pools out of 10000.
    function getEachPoolUtilization() public view returns (uint256[] memory utilization) {
        utilization = new uint256[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            address currentPool = pools[i];

            // use want in the pool and want borrowed from the pool to get our utilization
            uint256 totalBorrows = IBorrowable(currentPool).totalBorrows();
            uint256 totalSupplied = IBorrowable(currentPool).totalBalance().add(totalBorrows);
            utilization[i] = totalBorrows.mul(BASIS_PRECISION).div(totalSupplied);
        }
    }

    /// @notice This returns the allocation of our want balance to each pool
    function getCurrentPoolAllocations() external view returns (uint256[] memory allocation) {
        allocation = new uint256[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            allocation[i] = wantSuppliedToPool(pools[i]);
        }
    }

    /// @notice View the current order of our pool addresses in use.
    function getPools() external view returns (address[] memory poolsOrder) {
        poolsOrder = new address[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            poolsOrder[i] = pools[i];
        }
    }

    // see how much want we have supplied to a given pool
    function wantSuppliedToPool(address _pool) internal view returns (uint256 wantBal) {
        uint256 bTokenBalance = IBorrowable(_pool).balanceOf(address(this));
        uint256 currentExchangeRate = IBorrowable(_pool).exchangeRateLast();
        wantBal = bTokenBalance.mul(currentExchangeRate).div(BTOKEN_DECIMALS);
    }

    /// @notice Reorder our array of pools by increasing utilization. Deposits go to the last pool, withdrawals start from the front.
    function reorderPools() public onlyEmergencyAuthorized {
        uint256[] memory utilizations = getEachPoolUtilization();
        if (utilizations.length > 1) {
            _reorderPools(utilizations, 0, utilizations.length - 1);
        }
    }

    function _reorderPools(
        uint256[] memory utilizations,
        uint256 low,
        uint256 high
    ) internal {
        if (low < high) {
            uint256 pivotVal = utilizations[(low + high) / 2];

            uint256 low1 = low;
            uint256 high1 = high;
            for (;;) {
                while (utilizations[low1] < pivotVal) low1++;
                while (utilizations[high1] > pivotVal) high1--;
                if (low1 >= high1) break;
                (utilizations[low1], utilizations[high1]) = (utilizations[high1], utilizations[low1]);
                (pools[low1], pools[high1]) = (pools[high1], pools[low1]);
                (preventDeposits[low1], preventDeposits[high1]) = (preventDeposits[high1], preventDeposits[low1]);
                low1++;
                high1--;
            }
            if (low < high1) _reorderPools(utilizations, low, high1);
            high1++;
            if (high1 < high) _reorderPools(utilizations, high1, high);
        }
    }

    /* ========== CORE MUTATIVE FUNCTIONS ========== */

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

        // this is where we record our profit and (hopefully no) losses
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 wantBal = balanceOfWant();

        if (assets >= debt) {
            // prevent overflow if we have losses
            _profit = assets.sub(debt);
        } else {
            _loss = debt.sub(assets);
        }

        _debtPayment = _debtOutstanding;
        uint256 toFree = _debtPayment.add(_profit);

        // this will almost always be true
        if (toFree > wantBal) {
            toFree = toFree.sub(wantBal);

            _withdraw(toFree);

            // check what we got back out
            wantBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, wantBal);

            // make sure we pay our debt first, then count profit. if not enough to pay debt, then only loss.
            if (wantBal > _debtPayment) {
                _profit = wantBal.sub(_debtPayment);
            } else {
                _profit = 0;
                _loss = _debtPayment.sub(wantBal);
            }
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function updateExchangeRates() internal {
        // Update all the rates before harvest or withdrawals
        for (uint256 i = 0; i < pools.length; i++) {
            address targetPool = pools[i];

            IBorrowable(targetPool).exchangeRate();
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
        // Deposit to highest utilization pair, which should be last in our pools array
        for (uint256 i = (pools.length - 1); i >= 0; i--) {
            if (!preventDeposits[i]) {
                // only deposit to this pool if it's not shutting down.
                address targetPool = pools[i];
                want.transfer(targetPool, _depositAmount);
                IBorrowable(targetPool).mint(address(this));
                break;
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
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

        // use this to check if our debtRatio is 0
        StrategyParams memory params = vault.strategies(address(this));

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

            // figure out how much bToken we are able to burn from this pool for want.
            uint256 ableToPullInbToken = ableToPullInUnderlying.mul(BTOKEN_DECIMALS).div(IBorrowable(currentPool).exchangeRateLast());

            // check if we need to pull as much as possible from our pools
            if (params.debtRatio == 0 || _amountToWithdraw == type(uint256).max || vaultAPIExtended(address(vault)).emergencyShutdown()) {
                // this is for withdrawing the maximum we safely can
                if (PoolLiquidity > suppliedToPool) {
                    // if possible, burn our whole bToken position to avoid dust
                    uint256 balanceOfbToken = IBorrowable(currentPool).balanceOf(address(this));
                    IBorrowable(currentPool).transfer(currentPool, balanceOfbToken);
                    IBorrowable(currentPool).redeem(address(this));
                } else {
                    // otherwise, withdraw as much as we can
                    IBorrowable(currentPool).transfer(currentPool, ableToPullInbToken);
                    IBorrowable(currentPool).redeem(address(this));
                }
                continue;
            }

            // this is how much we need, converted to the bTokens of this specific pool. add 5 wei as a buffer for calculation losses.
            uint256 remainingbTokenNeeded =
                remainingUnderlyingNeeded.mul(BTOKEN_DECIMALS).div(IBorrowable(currentPool).exchangeRateLast()).add(5);

            // Withdraw all we need from the current pool if we can
            if (ableToPullInbToken > remainingbTokenNeeded) {
                IBorrowable(currentPool).transfer(currentPool, remainingbTokenNeeded);
                uint256 pulled = IBorrowable(currentPool).redeem(address(this));

                // add what we just withdrew to our total
                withdrawn = withdrawn.add(pulled);
                break;
            }
            //Otherwise withdraw what we can from current pool
            else {
                // if there is more free liquidity than our amount deposited, just burn the whole bToken balance so we don't have dust
                uint256 pulled;
                if (PoolLiquidity > suppliedToPool) {
                    uint256 balanceOfbToken = IBorrowable(currentPool).balanceOf(address(this));
                    IBorrowable(currentPool).transfer(currentPool, balanceOfbToken);
                    pulled = IBorrowable(currentPool).redeem(address(this));
                } else {
                    IBorrowable(currentPool).transfer(currentPool, ableToPullInbToken);
                    pulled = IBorrowable(currentPool).redeem(address(this));
                }
                // add what we just withdrew to our total, subtract it from what we still need
                withdrawn = withdrawn.add(pulled);

                // don't want to overflow
                if (remainingUnderlyingNeeded > pulled) {
                    remainingUnderlyingNeeded = remainingUnderlyingNeeded.sub(pulled);
                } else {
                    remainingUnderlyingNeeded = 0;
                }
            }
        }
    }

    function emergencyWithdraw(uint256 _amountToWithdraw) external onlyEmergencyAuthorized {
        _withdraw(_amountToWithdraw);
    }

    // this will withdraw the maximum we can based on free liquidity and take a loss for any locked funds
    function liquidateAllPositions() internal virtual override returns (uint256 _liquidatedAmount) {
        _withdraw(type(uint256).max);
        _liquidatedAmount = balanceOfWant();
    }

    // transfer our bTokens directly to our new strategy
    function prepareMigration(address _newStrategy) internal override {
        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            IBorrowable bToken = IBorrowable(pools[i]);

            uint256 balanceOfbToken = bToken.balanceOf(address(this));
            if (balanceOfbToken > 0) {
                bToken.transfer(_newStrategy, balanceOfbToken);
            }
        }
    }

    /* ========== PERIPHERAL MUTATIVE FUNCTIONS ========== */

    /// @notice Manually set allocations for our attached pools in bps (1 = 0.01%)
    function manuallySetAllocations(uint256[] calldata _ratios) external onlyAuthorized {
        // length of ratios must match number of pairs
        require(_ratios.length == pools.length);

        uint256 totalRatio;
        for (uint256 i = 0; i < pools.length; i++) {
            totalRatio += _ratios[i];
        }

        require(totalRatio == 10000); //ratios must add to 10000 bps

        // Update our rates before reorganizing
        updateExchangeRates();

        // withdraw the max we can from our pools before re-allocating
        _withdraw(type(uint256).max);

        // if some amount is locked in some pools, we don't care
        uint256 startingWantBalance = balanceOfWant();

        for (uint256 i = 0; i < pools.length; i++) {
            uint256 toAllocate = _ratios[i].mul(startingWantBalance).div(BASIS_PRECISION);
            if (toAllocate > 0) {
                address targetPool = pools[i];
                uint256 currentWantBalance = balanceOfWant();
                uint256 toDeposit = Math.min(currentWantBalance, toAllocate);
                want.transfer(targetPool, toDeposit);
                IBorrowable(targetPool).mint(address(this));
            }
        }

        // reorder our pools based on utilization
        reorderPools();
    }

    ///@notice Add another Tarot pool to our strategy for lending. This can only be called by governance.
    function addTarotPool(address _newPool) external onlyGovernance {
        // asset must match want.
        require(IBorrowable(_newPool).underlying() == address(want));

        for (uint256 i = 0; i < pools.length; i++) {
            // pool must not already be attached
            require(_newPool != pools[i]);
        }
        pools.push(_newPool);
        preventDeposits.push(false);
    }

    /// @notice This is used for shutting down lending to a particular pool gracefully. May need to be called more than once for a given pool.
    function attemptToRemovePool(address _poolToRemove) external onlyEmergencyAuthorized {
        // amount strategy has supplied to this pool
        uint256 suppliedToPool = wantSuppliedToPool(_poolToRemove);

        // total liquidity available in the pool in want
        uint256 PoolLiquidity = want.balanceOf(_poolToRemove);

        // get our exchange rate for this pool of bToken to want
        uint256 currentExchangeRate = IBorrowable(_poolToRemove).exchangeRateLast();

        // use helpers pool to keep track of multiple pools that are being shutdown or removed.
        bool[] memory boolHelperPool = preventDeposits;
        delete preventDeposits;

        address[] memory addressHelperPool = pools;
        delete pools;

        // Check if there is enough liquidity to withdraw our whole position immediately
        if (PoolLiquidity > suppliedToPool) {
            // burn all of our bToken
            uint256 balanceOfbToken = IBorrowable(_poolToRemove).balanceOf(address(this));
            if (balanceOfbToken > 0) {
                IBorrowable(_poolToRemove).transfer(_poolToRemove, balanceOfbToken);
                IBorrowable(_poolToRemove).redeem(address(this));
            }
            require(IBorrowable(_poolToRemove).balanceOf(address(this)) == 0);

            // we can now remove this pool from our array
            for (uint256 i = 0; i < boolHelperPool.length; i++) {
                if (addressHelperPool[i] == _poolToRemove) {
                    // we don't want to re-add the pool we just successfully emptied
                    continue;
                } else if (!boolHelperPool[i]) {
                    // these are normal pools that allow deposits
                    preventDeposits.push(false);
                } else {
                    // if the pool is emptying but not the one we're removing, leave it as true.
                    preventDeposits.push(true);
                }
                pools.push(addressHelperPool[i]); // if we didn't remove a pool, make sure to add it back to our pools
            }
        } else {
            // Otherwise withdraw the most want we can withdraw from this pool
            uint256 ableToPullInUnderlying = Math.min(suppliedToPool, PoolLiquidity);

            // convert that to bToken and redeem (withdraw)
            uint256 ableToPullInbToken = ableToPullInUnderlying.mul(BTOKEN_DECIMALS).div(currentExchangeRate);
            if (ableToPullInbToken > 0) {
                IBorrowable(_poolToRemove).transfer(_poolToRemove, ableToPullInbToken);
                IBorrowable(_poolToRemove).redeem(address(this));
            }

            // we can now remove this pool from our array
            for (uint256 i = 0; i < boolHelperPool.length; i++) {
                if (addressHelperPool[i] == _poolToRemove) {
                    // this is our pool we are targeting, but it's not empty yet
                    preventDeposits.push(true);
                } else if (!boolHelperPool[i]) {
                    // these are normal pools that allow deposits
                    preventDeposits.push(false);
                } else {
                    // this allows us to be emptying multiple pools at once. if the pool is emptying but not the one we're removing, leave it alone.
                    preventDeposits.push(true);
                }
                pools.push(addressHelperPool[i]); // if we didn't remove a pool, make sure to add it back to our pools
            }
        }
        require(pools.length == preventDeposits.length); // use this to ensure we didn't mess up the length of our arrays

        // deposit our free want into our other pools
    }

    function manuallySetOrder(address[] memory _poolOrder) external onlyEmergencyAuthorized {
        // new length must match number of pairs
        require(_poolOrder.length == pools.length);

        //Delete old entries and overwrite with new ones
        delete pools;
        for (uint256 i = 0; i < _poolOrder.length; i++) {
            pools.push(_poolOrder[i]);
        }
    }

    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyAuthorized {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    ///@notice This allows us to turn off automatic reordering during harvests
    function setReorder(bool _reorder) external onlyAuthorized {
        reorder = _reorder;
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

    function protectedTokens() internal view override returns (address[] memory) {}
}
