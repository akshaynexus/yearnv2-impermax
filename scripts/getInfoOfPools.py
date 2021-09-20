from brownie import interface
def main():
    newalloc = [
        ["0x9cDED654472788a143C2285A6b2a580392510688", 1102],#WFTM-YFI
        ["0xDf79EA5d777F28cAb9fD42ACda6208a228c71B59", 1095],# WFTM-LINK
        ["0xF2D3AE45F8775bA0a729dF47210164F921Edc306", 1082],#WFTM-LINK
        ["0x37F6Cf24bA9E781344Ae4aC8923d9A0A3910bc64", 1076],#WFTM-SUSHI
        ["0x0c60dbD5b78d1488F9f71163E598d90f8EDE55E7", 1064],#WFTM-WOOFY
        ["0x4e4a8AE836cBE9576113706e166ae1194A7113E6", 1053],#WFTM-MIM
        ["0x00Fb23C7169E0378a63D9cFE50Ef40f944653c69", 1035],#WFTM-SUSHI
        ["0xB566727F4edF30bA13939E304d828e30d4063C59", 960],#WFTM-MIM
        ["0xD05f23002f6d09Cf7b643B69F171cc2A3EAcd0b3", 769],#WFTM-BOO
        ["0x5dd76071F7b5F4599d4F2B7c08641843B746ace9", 764],#WFTM-TAROT
    ]
    for i in range(len(newalloc)):
        pool = newalloc[i][0]
        print(pool)
        collateral = interface.ICollateral(interface.ILendingPoolToken(pool).collateral())
        print(f"collateral : {collateral}")
        pair = interface.IUniswapV2Pair(interface.IVaultToken(collateral.underlying()).underlying())
        token0 = interface.ERC20(pair.token0())
        token1 = interface.ERC20(pair.token1())
        print(f"Name : {token0.symbol()}-{token1.symbol()}")
        reserves = pair.getReserves()
        print(f"LPFunds : {reserves[0] / 10**token0.decimals()} {token0.symbol()} - {reserves[1] / 10**token1.decimals()} {token1.symbol()}")