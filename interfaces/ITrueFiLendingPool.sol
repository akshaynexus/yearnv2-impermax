pragma solidity 0.6.12;

interface ITrueFiLendingPool {
    function joiningFee (  ) external view returns ( uint256 );
    function liquidExitPenalty ( uint256 amount ) external view returns ( uint256 );
    function join ( uint256  ) external;
    function liquidExit ( uint256 amount ) external;
    function pauseStatus (  ) external view returns ( bool );
    function pull ( uint256 minTokenAmount ) external;
    function token (  ) external view returns ( address );
}