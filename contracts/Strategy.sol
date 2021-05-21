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
import "../libraries/OneInch.sol";
import "../interfaces/IUniRouterV2.sol";

import "../interfaces/ITrueFiLendingPool.sol";
import "../interfaces/ITrueFarm.sol";
interface ITrueFiLendingPoolToken is ITrueFiLendingPool, IERC20 {}
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using SafeERC20 for ITrueFiLendingPoolToken;
    using Address for address;
    using SafeMath for uint256;
    using OneInchExchange for I1Inch3;

    uint256 private constant BASIS_PRECISION = 10000;
    uint16 public constant TOLERATED_SLIPPAGE = 100; // 1%
    uint256 public depositFeesToCover;

    address public OneInch;

    IERC20 public constant TRU = IERC20(0x4C19596f5aAfF459fA38B0f7eD92F11AE6543784);
    address private constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    //Sushiswap router has the highest liq by far,so we use this
    IUniRouterV2 public router = IUniRouterV2(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    //This contract mints lend position tokens on deposit
    ITrueFiLendingPoolToken lender;
    //We deposit the lender tokens in this contract to gain TRU rewards
    ITrueFarm truFarm;

    //1Inch instance for best output
    I1Inch3 _1INCH;

    event Cloned(address indexed clone);

    constructor(address _vault,address _truefilendpool, address _farm) public BaseStrategy(_vault) {
        _initializeStrat(_truefilendpool,_farm);
    }

    function _initializeStrat(
        address _truefilendpool,
        address _farm
    ) internal {
        require(
            address(lender) == address(0),
            "Strategy already initialized"
        );

        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 6300;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;

        lender = ITrueFiLendingPoolToken(_truefilendpool);
        require(lender.token() == address(want),"Wrong want token");
        truFarm = ITrueFarm(_farm);
        //Approve lending contract to spend want
        want.safeApprove(_truefilendpool, type(uint256).max);
        //Approve farming contract to spend lend token
        lender.safeApprove(_farm, type(uint256).max);
        //Set 1inch v3 router address
        OneInch = 0x11111112542D85B3EF69AE05771c2dCCff4fAa26;
        _1INCH = I1Inch3(OneInch);

        TRU.safeApprove(address(router), type(uint256).max);
        TRU.safeApprove(OneInch, type(uint256).max);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _truefilendpool,
        address _farm
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_truefilendpool, _farm);
    }

    function cloneStrategy(
        address _vault,
        address _staker,
        address _router,
        address _truefilendpool,
        address _farm
    ) external returns (address newStrategy) {
        newStrategy = this.cloneStrategy(
            _vault,
            msg.sender,
            msg.sender,
            msg.sender,
            _truefilendpool,
            _farm
        );
    }

    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _truefilendingpool,
        address _farm
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _truefilendingpool,
            _farm
        );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return "StrategyTrueFiLender";
    }

    // returns balance of 1INCH
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfLendToken() public view returns (uint256) {
        return lender.balanceOf(address(this));
    }

    //Returns staked value
    function balanceOfStake() public view returns (uint256) {
        return truFarm.staked(address(this));
    }

    function pendingReward() public view returns (uint256) {
        return truFarm.claimable(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the want balance and staked balance
        return balanceOfWant().add(balanceOfStake());
    }
    function _claimAndSwapNoOneInch() internal {
            //Claim Tru rewards
            truFarm.claim();
            //Swap through sushiswap
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                TRU.balanceOf(address(this)),
                0,
                getTokenOutPath(address(TRU),address(want)),
                address(this),
                block.timestamp
            );
    }

    //TODO create prepare return for oneinch swap
    function _claimAndSwap(bytes calldata _oneInch) internal {
        //Claim Tru rewards
        truFarm.claim();
        //Swap TRU to USDC,also check the data before doing so
        if(_oneInch.length > 0) {
            //Taken from Truefi lending pool code
            uint256 balanceBefore = balanceOfWant();

            I1Inch3.SwapDescription memory swap = _1INCH.exchange(_oneInch);

            //Uses spot output from sushiswap router as minout
            uint256 expectedGain = getEstimatedOut(swap.amount);

            uint256 balanceDiff = balanceOfWant().sub(balanceBefore);
            require(balanceDiff >= withToleratedSlippage(expectedGain), "Strategy: Not optimal exchange");

            require(swap.srcToken == address(TRU), "Strategy: Invalid srcToken");
            require(swap.dstToken == address(want), "Strategy: Invalid destToken");
            require(swap.dstReceiver == address(this), "Strategy: Receiver is not strat");
        }
    }

    /**
     * @dev Get token swap path routed via weth
     * @param _token_in token to swap from
     * @param _token_out token to swap to
     * @return _path array for swap path
     */
    function getTokenOutPath(address _token_in,address _token_out ) internal view returns (address [] memory _path) {
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

    /**
     * @dev Decrease provided amount percentwise by error
     * @param amount Amount to decrease
     * @return Calculated value
     */
    function withToleratedSlippage(uint256 amount) internal pure returns (uint256) {
        return amount.mul(BASIS_PRECISION - TOLERATED_SLIPPAGE).div(BASIS_PRECISION);
    }

    /**
     * @dev Get amount out if swapped via router
     * @param truIn Amount of TRU to swap
     * @return Estimated Output in want
     */
    function getEstimatedOut(uint truIn) internal view returns (uint){
        uint[] memory amounts = router.getAmountsOut(truIn,getTokenOutPath(address(TRU),address(want)));
        return amounts[amounts.length - 1];
    }

    function returnDebtOutstanding(uint256 _debtOutstanding) internal returns (uint _debtPayment, uint _loss) {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }
    }

    function handleProfit() internal returns (uint _profit) {
        uint256 balanceOfWantBefore = balanceOfWant();
        if(pendingReward() > 0)
            _claimAndSwapNoOneInch();
        uint baseProfit = balanceOfWant().sub(balanceOfWantBefore);
        //Subtract deposit fees from profit if we have any left to cover
        depositFeesToCover = depositFeesToCover > baseProfit ? depositFeesToCover.sub(baseProfit) : 0;
        _profit = depositFeesToCover > baseProfit ? 0 : baseProfit.sub(depositFeesToCover);
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
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();

        if (_debtOutstanding >= _wantAvailable) {
            return;
        }

        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
            //First lend to lender to get lend tokens
            lender.join(toInvest);
            //add loss to cover if we get lesser than what we enter with
            uint balLend = balanceOfLendToken();
            if(balLend < toInvest) depositFeesToCover = depositFeesToCover.add(toInvest.sub(balLend));
            //Stake those tokens to tru farm for tru rewards
            truFarm.stake(balanceOfLendToken());
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 balanceStaked = balanceOfStake();
        if (_amountNeeded > balanceWant) {
            uint amountToWithdraw = (Math.min(balanceStaked, _amountNeeded - balanceWant));
            // unstake needed amount
            truFarm.unstake(amountToWithdraw);
            lender.liquidExit(amountToWithdraw);
        }
        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
    }

    function prepareMigration(address _newStrategy) internal override {
        // If we have pending rewards,take that out
        if(pendingReward() > 0){
            _claimAndSwapNoOneInch();
        }
        liquidatePosition(type(uint256).max);
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    function protectedTokens() internal view override returns (address[] memory) {}
}
