// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/ILendingPool.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

interface ILendingPoolToken is ILendingPool, IERC20Extended {}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILendingPoolToken;
    using Address for address;
    using SafeMath for uint256;

    struct PoolAlloc {
        address pool;
        uint256 pools;
    }

    uint256 private constant BASIS_PRECISION = 10000;
    uint256 internal constant TAROT_MIN_TARGET_UTIL = 7e17; // 70%
    uint256 internal constant TAROT_MAX_TARGET_UTIL = 8e17; // 80%
    uint256 internal constant UTIL_PRECISION = 1e18;
    bool internal isOriginal = true;

    uint256 public minProfit;
    uint256 public minCredit;

    //Spookyswap as default
    IUniswapV2Router02 internal router;
    address internal weth;

    //This records the current pools and allocs
    address[] public pools;

    event Cloned(address indexed clone);

    constructor(address _vault, address[] memory _pools) public BaseStrategy(_vault) {
        _initializeStrat(_pools);
    }

    function _initializeStrat(address[] memory _pools) internal {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 6300;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;

        //Spookyswap router
        router = IUniswapV2Router02(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
        weth = router.WETH();
        _setPools(_pools);
        addApprovals();
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address[] memory _pools
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_pools);
    }

    function cloneStrategy(address _vault, address[] memory _pools) external returns (address newStrategy) {
        newStrategy = this.cloneStrategy(_vault, msg.sender, msg.sender, msg.sender, _pools);
    }

    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address[] memory _pools
    ) external returns (address newStrategy) {
        require(isOriginal,"!original");
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

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _pools);

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return "StrategyTarotLender";
    }

    function wantTobToken(address _pool, uint256 _requiredWant) internal view returns (uint256 _amount) {
        if (_requiredWant == 0) return _requiredWant;
        // This gives us the price per share of xToken
        uint256 pps = ILendingPool(_pool).exchangeRateLast();
        //Now calculate based on pps
        _amount = _requiredWant.mul(1e18).div(pps);
    }

    function bTokenToWant(address _pool, uint256 _bBal) public view returns (uint256 _amount) {
        if (_bBal == 0) return _bBal;
        // This gives us the price per share of xToken
        uint256 pps = ILendingPool(_pool).exchangeRateLast();
        _amount = (_bBal.mul(pps)).div(1e18);
    }

    function balanceInPool(address _pool) internal view returns (uint256 bal) {
        bal = bTokenToWant(_pool, ILendingPoolToken(_pool).balanceOf(address(this)));
    }

    function _getTotalSuppliedInPool(address _pool) internal view returns (uint256 tSupply) {
        tSupply = bTokenToWant(_pool, ILendingPoolToken(_pool).totalSupply());
    }

    function _getBorrowedInPair(address _pool) internal view returns (uint256 tBorrow) {
        tBorrow = _getTotalSuppliedInPool(_pool).sub(want.balanceOf(_pool));
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    //Returns staked value
    function balanceOfStake() public view returns (uint256 total) {
        for (uint256 i = 0; i < pools.length; i++) {
            total = total.add(balanceInPool(pools[i]));
        }
    }

    function pendingInterest() public view returns (uint256) {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 lendBal = estimatedTotalAssets();
        if (debt < lendBal) {
            //This will add to profit
            return lendBal.sub(debt);
        }
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the want balance and staked balance
        return balanceOfWant().add(balanceOfStake());
    }

    function tendTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        return super.tendTrigger(callCostInWei) || balanceOfWant() > minCredit;
    }

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        return super.harvestTrigger(callCostInWei) || pendingInterest() > minProfit || vault.creditAvailable() > minCredit;
    }

    function getTotalPools() external view returns (uint256) {
        return pools.length;
    }

    function getWithdrawableFromPools() public view returns (uint256[] memory availableAmounts) {
        availableAmounts = new uint256[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            uint256 liqAvail = want.balanceOf(pools[i]);
            uint256 deposited = balanceInPool(pools[i]);
            availableAmounts[i] = Math.min(deposited, liqAvail);
        }
    }

    function getMaxWithdrawable() public view returns (uint256 liquidity) {
        uint256[] memory availableAmounts = getWithdrawableFromPools();
        for (uint256 i = 0; i < availableAmounts.length; i++) {
            liquidity += availableAmounts[i];
        }
    }

    // The following utilization helper functions are taken from kashi lending strat,rewritten to support tarot/impermax lending
    function lendPairUtilization(address _lendingPair, uint256 assetsToDeposit) public view returns (uint256) {
        uint256 totalAssets = _getTotalSuppliedInPool(_lendingPair);
        uint256 totalBorrowAmount = _getBorrowedInPair(_lendingPair);
        return uint256(totalBorrowAmount).mul(UTIL_PRECISION).div(totalAssets);
    }

    // highestInterestIndex finds the best pair to invest the given deposit
    function highestInterestPair(uint256 assetsToDeposit) public view returns (address _highestPair) {
        uint256 highestInterest = 0;
        uint256 highestUtilization = 0;

        for (uint256 i = 0; i < pools.length; i++) {
            uint256 utilization = lendPairUtilization(pools[i], assetsToDeposit);

            // A pair is highest (really best) if either
            //   - It's utilization is higher, and either
            //     - It is above the max target util
            //     - The existing choice is below the min util target
            //   - Compare APR directly only if both are between the min and max
            if (
                (utilization > highestUtilization && (utilization > TAROT_MAX_TARGET_UTIL || highestUtilization < TAROT_MIN_TARGET_UTIL)) ||
                (utilization < TAROT_MAX_TARGET_UTIL &&
                    utilization > TAROT_MIN_TARGET_UTIL &&
                    highestUtilization < TAROT_MAX_TARGET_UTIL &&
                    highestUtilization > TAROT_MIN_TARGET_UTIL)
            ) {
                highestUtilization = utilization;
                _highestPair = pools[i];
            }
        }
    }

    function lowestInterestPair(uint256 minLiquidShares) public view returns (address _lowestPair) {
        uint256 lowestUtilization = UTIL_PRECISION;

        for (uint256 i = 0; i < pools.length; i++) {
            uint256 utilization = lendPairUtilization(pools[i], 0);

            // A pair is lowest if either
            //   - It's utilization is lower, and either
            //     - It is below the min taget util
            //     - The existing choice is above the max target util
            //   - Compare APR directly only if both are between the min and max
            if (
                ((utilization < lowestUtilization && (lowestUtilization > TAROT_MAX_TARGET_UTIL || utilization < TAROT_MIN_TARGET_UTIL)) ||
                    (utilization < TAROT_MAX_TARGET_UTIL &&
                        utilization > TAROT_MIN_TARGET_UTIL &&
                        lowestUtilization < TAROT_MAX_TARGET_UTIL &&
                        lowestUtilization > TAROT_MIN_TARGET_UTIL)) &&
                want.balanceOf(pools[i]) >= minLiquidShares &&
                balanceInPool(pools[i]) > 0
            ) {
                _lowestPair = pools[i];
            }
        }
    }

    function _depositToPool(address _pool, uint256 _amount) internal {
        if (_amount > 0) {
            want.safeTransfer(_pool, _amount);
            require(ILendingPoolToken(_pool).mint(address(this)) >= 0, "No lend tokens minted");
        }
    }

    function updateExchangeRates() internal {
        //Update all the rates before harvest
        for (uint256 i = 0; i < pools.length; i++) {
            ILendingPool(pools[i]).exchangeRate();
        }
    }

    function calculatePTAmount(address _pool, uint256 _amount) internal returns (uint256 pAmount) {
        uint256 pBal = ILendingPoolToken(_pool).balanceOf(address(this));
        //Reduce _amount if avail liq is < _amount
        _amount = Math.min(_amount, want.balanceOf(_pool));
        //Reduce pAmount if pAmount > pBal
        pAmount = Math.min(pBal, wantTobToken(_pool, _amount));
    }

    function adjustToLiq(address _pool) internal returns (uint256) {
        uint256 pBal = ILendingPoolToken(_pool).balanceOf(address(this));
        //Reduce _amount if avail liq is < _amount
        uint256 _amount = want.balanceOf(_pool);
        //Reduce pAmount if pAmount > pBal
        return Math.min(pBal, wantTobToken(_pool, _amount));
    }

    function _withdrawFrom(address _pool) internal returns (uint256 returnAmt) {
        uint256 pAmount = adjustToLiq(_pool);
        if (pAmount > 0) {
            ILendingPoolToken(_pool).safeTransfer(_pool, pAmount);
            returnAmt = ILendingPoolToken(_pool).redeem(address(this));
        }
    }

    function _withdrawFromPool(address _pool, uint256 _amount) internal returns (uint256 returnedAmount) {
        uint256 liqAvail = want.balanceOf(_pool);
        _amount = Math.min(_amount, liqAvail);
        uint256 pAmount = calculatePTAmount(_pool, _amount);
        uint256 balWant = balanceOfWant();
        if (pAmount > 0) {
            //Extra addition on liquidate position to cover edge cases of a few wei defecit
            ILendingPoolToken(_pool).safeTransfer(_pool, pAmount);
            returnedAmount = ILendingPoolToken(_pool).redeem(address(this));
        }
        if (returnedAmount < _amount) {
            //Withdraw all and reinvest remaining
            uint256 toCover = _amount.sub(returnedAmount);
            pAmount = calculatePTAmount(_pool, _amount);
            if (pAmount > 0) {
                ILendingPoolToken(_pool).safeTransfer(_pool, pAmount);
                require(ILendingPoolToken(_pool).redeem(address(this)) >= 0, "Not enough returned");
            }
        }
        //Set true returned amount here
        returnedAmount = balanceOfWant().sub(balWant);
    }

    function _withdrawLowUtil(uint256 _amount) internal returns (uint256 remainingAmount) {
        address lowestPair = lowestInterestPair(_amount);
        if (lowestPair != address(0)) {
            uint256 returnedAmount = _withdrawFromPool(lowestPair, _amount);
            remainingAmount = returnedAmount >= _amount ? 0 : _amount.sub(returnedAmount);
        }
    }

    function _withdrawOptimal(uint256 _amount) internal {
        //First try to withdraw from lowest liq pair
        uint256 _remainingToWithdraw = _withdrawLowUtil(_amount);

        for (uint256 i = 0; i < pools.length && _remainingToWithdraw > 0; i++) {
            uint256 balInPool = balanceInPool(pools[i]);
            uint256 liq = want.balanceOf(pools[i]);
            //Withdraw from pool if there is enough liq
            if (liq >= _remainingToWithdraw && balInPool > 0) {
                uint256 _amountReturned = _withdrawFromPool(pools[i], _remainingToWithdraw);
                _remainingToWithdraw = _amountReturned < _remainingToWithdraw ? _remainingToWithdraw.sub(_amountReturned) : 0;
            }
            //Otherwise withdraw all from current pool
            else if (balInPool > 0) {
                _remainingToWithdraw = _remainingToWithdraw.sub(_withdrawFrom(pools[i]));
            }
        }
    }

    function _deposit(uint256 _depositAmount) internal {
        //Deposit to highest pair
        address highestPair = highestInterestPair(_depositAmount);
        _depositToPool(highestPair, _depositAmount);
    }

    function _withdrawAll() internal {
        for (uint256 i = 0; i < pools.length; i++) {
            _withdrawFrom(pools[i]);
        }
    }

    function _withdraw(uint256 _withdrawAmount) internal {
        //Update before trying to withdraw
        updateExchangeRates();
        _withdrawOptimal(_withdrawAmount);
    }

    function revokeApprovals() internal {
        for (uint256 i = 0; i < pools.length; i++) {
            want.approve(pools[i], 0);
        }
    }

    function addApprovals() internal {
        for (uint256 i = 0; i < pools.length; i++) {
            if (want.allowance(address(this), pools[i]) == 0) want.approve(pools[i], type(uint256).max);
        }
    }

    function updateMinProfit(uint256 _minProfit) external onlyAuthorized {
        minProfit = _minProfit;
    }

    function updateMinCredit(uint256 _minCredit) external onlyAuthorized {
        minCredit = _minCredit;
    }

    function changeAllocs(address[] memory _newPools) external onlyGovernance {
        uint256 balStake = balanceOfStake();
        // Withdraw from all positions currently allocated
        if (balStake > 0 && balStake <= getMaxWithdrawable()) {
            _withdrawAll();
            revokeApprovals();
        }

        _setPools(_newPools);
        addApprovals();
        _deposit(balanceOfWant());
    }

    function setAllocManual(address[] memory _newPools) external onlyGovernance {
        _setPools(_newPools);
    }

    function withdrawFromPool(address _pool, uint256 amount) external onlyAuthorized {
        _withdrawFromPool(_pool, amount);
    }

    function moveFromPool(
        address _pool,
        uint256 amount,
        address _newPool
    ) external onlyGovernance {
        _withdrawFromPool(_pool, amount);
        // Make sure the _newPool is in pools conf,otherwise withdraws will fail
        _depositToPool(_newPool, amount);
    }

    function rebalance(uint256 amountToRebalance) external onlyAuthorized {
        _withdraw(amountToRebalance);
        _deposit(balanceOfWant());
    }

    function withdrawFromLending(uint256 amount) external onlyAuthorized {
        _withdraw(amount);
    }

    function _setPools(address[] memory _newPools) internal {
        //Delete old entries
        delete pools;
        for (uint256 i = 0; i < _newPools.length; i++) {
            pools.push(_newPools[i]);
        }
    }

    function _calculateAllocFromBal(uint256 _bal, uint256 _allocPoints) internal pure returns (uint256) {
        return _bal.mul(_allocPoints).div(BASIS_PRECISION);
    }

    function returnDebtOutstanding(uint256 _debtOutstanding) internal returns (uint256 _debtPayment, uint256 _loss) {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }
    }

    function handleProfit() internal returns (uint256 _profit) {
        uint256 balanceOfWantBefore = balanceOfWant();
        updateExchangeRates();
        _profit = pendingInterest();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        (_debtPayment, _loss) = returnDebtOutstanding(_debtOutstanding);
        _profit = handleProfit();
        uint256 balanceAfter = balanceOfWant();
        uint256 requiredWantBal = _profit.add(_debtPayment);
        if (balanceAfter < requiredWantBal) {
            //Withdraw enough to satisfy profit check
            _withdraw(requiredWantBal.sub(balanceAfter));
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();

        if (_debtOutstanding >= _wantAvailable) {
            return;
        }

        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
            _deposit(toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 balanceStaked = balanceOfStake();
        if (_amountNeeded > balanceWant) {
            uint256 amountToWithdraw = (Math.min(balanceStaked, _amountNeeded.sub(balanceWant)));
            _withdraw(amountToWithdraw);
        }
        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
        _loss = _amountNeeded > _liquidatedAmount ? _amountNeeded.sub(_liquidatedAmount) : 0;
    }

    function getTokenOutPath(address _token_in, address _token_out) internal view returns (address[] memory _path) {
        bool is_weth = _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function quote(
        address _in,
        address _out,
        uint256 _amtIn
    ) internal view returns (uint256) {
        address[] memory path = getTokenOutPath(_in, _out);
        return router.getAmountsOut(_amtIn, path)[path.length - 1];
    }

    function prepareMigration(address _newStrategy) internal override {
        _withdrawAll();
    }

    function liquidateAllPositions() internal virtual override returns (uint256 _amountFreed) {
        _withdrawAll();
        _amountFreed = balanceOfWant();
    }

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {
        return address(want) == address(weth) ? _amtInWei : quote(weth, address(want), _amtInWei);
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    function protectedTokens() internal view override returns (address[] memory) {}
}
