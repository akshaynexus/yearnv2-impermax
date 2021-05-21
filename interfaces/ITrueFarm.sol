pragma solidity 0.6.12;

interface ITrueFarm {
  function claim (  ) external;
  function claimable ( address account ) external view returns ( uint256 );
  function claimableReward ( address ) external view returns ( uint256 );
  function cumulativeRewardPerToken (  ) external view returns ( uint256 );
  function exit ( uint256 amount ) external;
  function previousCumulatedRewardPerToken ( address ) external view returns ( uint256 );
  function stake ( uint256 amount ) external;
  function staked ( address ) external view returns ( uint256 );
  function stakingToken (  ) external view returns ( address );
  function totalClaimedRewards (  ) external view returns ( uint256 );
  function totalFarmRewards (  ) external view returns ( uint256 );
  function totalStaked (  ) external view returns ( uint256 );
  function trueDistributor (  ) external view returns ( address );
  function trustToken (  ) external view returns ( address );
  function unstake ( uint256 amount ) external;
}