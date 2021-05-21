pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/I1Inch3.sol";

interface IUniPair {
    function token0() external view returns (address);

    function token1() external view returns (address);
}

library OneInchExchange {
    uint256 constant ADDRESS_MASK = 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
    uint256 constant REVERSE_MASK = 0x8000000000000000000000000000000000000000000000000000000000000000;

    function exchange(I1Inch3 _1inchExchange, bytes calldata data) internal returns (I1Inch3.SwapDescription memory description) {
        if (data[0] == 0x7c) {
            // call swap()
            (, description, ) = abi.decode(data[4:], (address, I1Inch3.SwapDescription, bytes));
        } else {
            // call unoswap()
            (address srcToken, uint256 amount, uint256 minReturn, bytes32[] memory pathData) =
                abi.decode(data[4:], (address, uint256, uint256, bytes32[]));
            description.srcToken = srcToken;
            description.amount = amount;
            description.minReturnAmount = minReturn;
            description.flags = 0;
            uint256 lastPath = uint256(pathData[pathData.length - 1]);
            IUniPair uniPair = IUniPair(address(lastPath & ADDRESS_MASK));
            bool isReverse = lastPath & REVERSE_MASK > 0;
            description.dstToken = isReverse ? uniPair.token0() : uniPair.token1();
            description.dstReceiver = address(this);
        }

        (bool success, ) = address(_1inchExchange).call(data);
        if (!success) {
            // Revert with original error message
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }
}
