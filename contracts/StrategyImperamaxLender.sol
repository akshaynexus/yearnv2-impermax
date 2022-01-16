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
import "./interfaces/IRouter.sol";

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

    IRouter constant router = IRouter(0x283e62CFe14b352dB8e30A9575481DCbf589Ad98);

    //This records the current pools and allocations
    address[] public pools;
    bool[] public preventDeposits; // use this if we want to shut down a pool

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us

    string internal stratName; // set our strategy name here

    // check for cloning
    bool internal isOriginal = true;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        address[] memory _pools,
        string memory _name
    ) public BaseStrategy(_vault) {
        _initializeStrat(_pools, _name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    function _initializeStrat(address[] memory _pools, string memory _name) internal {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 2 days;

        // set up our pools
        for (uint256 i = 0; i < _pools.length; i++) {
            pools.push(_pools[i]);
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

    function cloneTarotLender(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address[] memory _pools,
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

    /// @notice Calculate the true exchange rate of a tarot pool since theirs is "up-only".
    // ASK STORM, FP, WEASEL ET AL FOR FEEDBACK ABOUT USING THIS VS LIVE CALC.
    function trueExchangeRate(address _pool) public view returns (uint256) {
        uint256 totalBorrows = IBorrowable(_pool).totalBorrows();
        uint256 actualBalance = IBorrowable(_pool).totalBalance().add(totalBorrows);
        uint256 totalSupply = IBorrowable(_pool).totalSupply();

        return actualBalance.mul(BTOKEN_DECIMALS).div(totalSupply);
    }

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

    // debugging events, delete once we go to prod
    // event toWithdraw(uint256 toWithdraw);
    // event Withdrawn(uint256 pulled);
    // event toLiquidate(uint256 sttuff);
    // event DebugString(string stuff);

    // emit toLiquidate(_profit);
    // emit Withdrawn(_debtPayment);
    // emit toWithdraw(sttuff);
    // emit DebugString(sttuff);

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
                uint256 debtNeeded = Math.min(stakedBal, _debtOutstanding);
                // emit toWithdraw(debtNeeded);
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

            // check if we already have enough loose want from shutting down a pool
            if (_wantBal < _profit.add(_debtPayment)) {
                uint256 amountToFree = _profit.add(_debtPayment).sub(_wantBal);
                // emit toWithdraw(amountToFree);
                _withdraw(amountToFree);
            }
        }
        // if assets are less than debt, we are in trouble. Losses should never happen, but if it does, let's record it accurately.
        else {
            _loss = debt.sub(assets);
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
        for (uint256 i = pools.length; i > 0; i--) {
            i = i.sub(1);
            if (!preventDeposits[i]) {
                // only deposit to this pool if it's not shutting down.
                address targetPool = pools[i];
                want.transfer(targetPool, _depositAmount);
                require(IBorrowable(targetPool).mint(address(this)) >= 0, "Mint");
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
                // emit toWithdraw(debtNeeded);
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

            if (_amountToWithdraw == type(uint256).max) {
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
            uint256 remainingbTokenNeeded = remainingUnderlyingNeeded.mul(BTOKEN_DECIMALS).div(currentExchangeRate).add(5);

            // Withdraw all we need from the current pool if we can
            if (ableToPullInbToken > remainingbTokenNeeded) {
                IBorrowable(currentPool).transfer(currentPool, remainingbTokenNeeded);
                uint256 pulled = IBorrowable(currentPool).redeem(address(this));
                // emit DebugString("Just redeemed all we need");

                // add what we just withdrew to our total
                withdrawn = withdrawn.add(pulled);
                // emit Withdrawn(withdrawn);
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
                    // emit DebugString("Just redeemed a full bToken balance");
                    // emit Withdrawn(pulled);
                } else {
                    IBorrowable(currentPool).transfer(currentPool, ableToPullInbToken);
                    pulled = IBorrowable(currentPool).redeem(address(this));
                    // emit DebugString("Just redeemed a partial bToken balance");
                }
                // add what we just withdrew to our total, subtract it from what we still need
                withdrawn = withdrawn.add(pulled);
                // emit Withdrawn(withdrawn);

                // don't want to overflow
                if (remainingUnderlyingNeeded > pulled) {
                    remainingUnderlyingNeeded = remainingUnderlyingNeeded.sub(pulled);
                } else {
                    remainingUnderlyingNeeded = 0;
                }
                // emit toLiquidate(remainingUnderlyingNeeded);
            }
        }
        if (_amountToWithdraw > withdrawn) {
            // normally, we want to revert to prevent unnecessary losses.
            StrategyParams memory params = vault.strategies(address(this));

            require(
                params.debtRatio == 0 || vaultAPIExtended(address(vault)).emergencyShutdown() || _amountToWithdraw == type(uint256).max,
                "Low liquidity"
            );
        }
    }

    function emergencyWithdraw(uint256 _amountToWithdraw) external onlyEmergencyAuthorized {
        _withdraw(_amountToWithdraw);
    }

    // this will withdraw the maximum we can based on free liquidity and take a loss for any locked funds
    function liquidateAllPositions() internal virtual override returns (uint256 _liquidatedAmount) {
        _withdraw(estimatedTotalAssets());
        _liquidatedAmount = balanceOfWant();
    }

    // transfer our bTokens directly to our new strategy
    function prepareMigration(address _newStrategy) internal override {
        for (uint256 i = 0; i < pools.length; i++) {
            // save some gas by storing locally
            IBorrowable bToken = IBorrowable(pools[i]);

            uint256 balanceOfbToken = bToken.balanceOf(address(this));
            bToken.transfer(_newStrategy, balanceOfbToken);
        }
    }

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
                require(IBorrowable(targetPool).mint(address(this)) >= 0, "Mint");
            }
        }
    }

    function addTarotPool(address _newPair) external onlyGovernance {
        // kashPair asset must match want. Try and adapt this one?
        // require(IKashiPair(_newKashiPair).asset() == BIERC20(address(want)));

        for (uint256 i = 0; i < pools.length; i++) {
            // pool must not already be attached
            require(_newPair != pools[i]);
        }
        pools.push(_newPair);
        preventDeposits.push(false);
    }

    // add an event when a pool is removed successfully?
    // TAROT DEFINITELY MAKES DECIMALS LINE UP!!!!!!!! So the smallest unit for a USDC one is at the 6 decimals, so 6e-18 bToken = 6e-6 USDC. uses floor though!!!!!

    /// @notice This is used for shutting down lending to a particular pool gracefully. May need to be called more than once for a given pool.
    // comment this out when using lots of events to test so we don't go over bytecode limit
    function attemptToRemovePool(address _poolToRemove) external onlyEmergencyAuthorized {
        // amount strategy has supplied to this pool
        uint256 suppliedToPool = wantSuppliedToPool(_poolToRemove);

        // total liquidity available in the pool in want
        uint256 PoolLiquidity = want.balanceOf(_poolToRemove);

        // get our exchange rate for this pool of bToken to want
        uint256 currentExchangeRate = IBorrowable(_poolToRemove).exchangeRateLast();

        // use helpers pool to keep track of multiple pools that are being shutdown or removed.
        bool[] memory helperPool = preventDeposits;
        delete preventDeposits;

        address[] memory extraHelperPool = pools;
        delete pools;

        // Check if there is enough liquidity to withdraw our whole position immediately
        if (PoolLiquidity > suppliedToPool) {
            // burn all of our bToken
            uint256 balanceOfbToken = IBorrowable(_poolToRemove).balanceOf(address(this));
            if (balanceOfbToken > 0) {
                IBorrowable(_poolToRemove).transfer(_poolToRemove, balanceOfbToken);
                IBorrowable(_poolToRemove).redeem(address(this));
            }
            require(IBorrowable(_poolToRemove).balanceOf(address(this)) == 0, "Remainder");

            require(helperPool.length == extraHelperPool.length, "Helpers");

            // we can now remove this pool from our array
            for (uint256 i = 0; i < helperPool.length; i++) {
                if (extraHelperPool[i] == _poolToRemove) {
                    continue; // we don't want to re-add the pool we removed
                } else if (!helperPool[i]) {
                    // these are normal pools that allow deposits
                    preventDeposits.push(false);
                } else {
                    // this allows us to be emptying multiple pools at once. if the pool is emptying but not the one we're removing, leave it alone.
                    preventDeposits.push(true);
                }
                pools.push(extraHelperPool[i]); // if we're not removing a pool, make sure to add it back to our pools
            }
        } else {
            // Otherwise withdraw what we can from current pool
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
                if (extraHelperPool[i] == _poolToRemove) {
                    // this is our pool we are targeting
                    preventDeposits.push(true);
                } else if (!helperPool[i]) {
                    // these are normal pools that allow deposits
                    preventDeposits.push(false);
                } else {
                    // this allows us to be emptying multiple pools at once. if the pool is emptying but not the one we're removing, leave it alone.
                    preventDeposits.push(true);
                }
                pools.push(extraHelperPool[i]); // if we're not removing a pool, make sure to add it back to our pools
            }
        }
        require(pools.length == preventDeposits.length, "Pools");
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

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyAuthorized {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    // This allows us to turn off automatic reordering during harvests
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
