pragma solidity 0.6.12;

interface ILendingPool {
    function exchangeRate() external returns (uint256);

    function exchangeRateLast() external view returns (uint256);

    function collateral() external view returns (address);

    function mint(address minter) external returns (uint256);

    function redeem(address redeemer) external returns (uint256);
}
