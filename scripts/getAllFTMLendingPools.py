from brownie import Contract, interface

wftm = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"


class bcolors:
    HEADER = "\033[95m"
    OKBLUE = "\033[94m"
    OKCYAN = "\033[96m"
    OKGREEN = "\033[92m"
    WARNING = "\033[93m"
    FAIL = "\033[91m"
    ENDC = "\033[0m"
    BOLD = "\033[1m"
    UNDERLINE = "\033[4m"


def takeSecond(elem):
    return elem[1]


def main():
    factory = Contract("0x35C052bBf8338b06351782A565aa9AaD173432eA")
    lengthPools = factory.allLendingPoolsLength()
    #Prefilled,remove entries in array to get new entries
    lendingPools = [
        "0x74e657267D3588D6330CF719368627f8b6F13303",
        "0xD05f23002f6d09Cf7b643B69F171cc2A3EAcd0b3",
        "0x93a97db4fEA1d053C31f0B658b0B87f4b38e105d",
        "0x6e11aaD63d11234024eFB6f7Be345d1d5b8a8f38",
        "0xFf0BC3c7df0c247E5ce1eA220c7095cE1B6Dc745",
        "0x845b1619eB0C7C0F9bc7d5494a0b332f6D8Fd4f6",
        "0x7A7dd36BCca42952CC1E67BcA1Be44097fF5b644",
        "0xE4EB3bd58c6021de054505e85179bbD2EbC03566",
        "0x8254086911E2A08bf0a179E87A1d45fb6B0F64E9",
        "0x8958aa800Ea1BAa1c47A76CE441b9Ff95548fB6a",
        "0x60d5ef2B19078773FC7EA61599D7e5219218Bf8E",
        "0x7D0Eb2b3EDeC482c86e0d588a0f1b3A36b99D336",
        "0x4e4a8AE836cBE9576113706e166ae1194A7113E6",
        "0xB566727F4edF30bA13939E304d828e30d4063C59",
        "0xeaAb0Eb61326499a4BC79eCDbC6F3BB17B323dd6",
        "0x1CeE4Fd447D7Ce967FddAE4b7DA872A3a1d04F4B",
        "0xd875860D6c7386E296C21374EA789C5ce574C6dF",
        "0xbeB8c1266B6a561F2f10B2d242628D7Ed4bA458e",
        "0x604ea00f00C25747d369D9D114590a483e23ff48",
        "0x5B80b6e16147bc339e22296184F151262657A327",
        "0xf63D4894c605C246fBe238514355E3cD9680CFF0",
        "0x8C97Dcb6a6b08E8bEECE3D75e918FbC076C094ab",
        "0x5dd76071F7b5F4599d4F2B7c08641843B746ace9",
        "0x037d3b5213C53A54C5DE243AADE6e7BBd8858c70",
        "0xDf79EA5d777F28cAb9fD42ACda6208a228c71B59",
        "0x10A1ba0F63D71e83dc74f05c878223b2AE828300",
        "0xF2D3AE45F8775bA0a729dF47210164F921Edc306",
        "0x00Fb23C7169E0378a63D9cFE50Ef40f944653c69",
        "0x9cDED654472788a143C2285A6b2a580392510688",
        "0x0c60dbD5b78d1488F9f71163E598d90f8EDE55E7",
        "0x37F6Cf24bA9E781344Ae4aC8923d9A0A3910bc64",
    ]
    poolData = []
    for i in range(len(lendingPools)):
        lendingPools[i] = interface.ILendingPoolToken(lendingPools[i])
    #loop and get suitable lending pools for token
    if len(lendingPools) == 0:
        for i in range(lengthPools):
            pair = interface.IUniswapV2Pair(factory.allLendingPools(i))
            token0 = interface.ERC20(pair.token0())
            token1 = interface.ERC20(pair.token1())
            # print(f"LPToken : {pair}")
            # print(f"Name : {token0.symbol()}-{token1.symbol()}")
            # reserves = pair.getReserves()
            # print(f"LPFunds : {reserves[0] / 10**token0.decimals()} {token0.symbol()} - {reserves[1] / 10**token1.decimals()} {token1.symbol()}")
            lendable = ""
            if token0.address == wftm:
                lendable = interface.ILendingPoolToken(factory.getLendingPool(pair)[3])
                lendingPools.append(lendable)
            elif token1.address == wftm:
                lendable = interface.ILendingPoolToken(factory.getLendingPool(pair)[4])
                lendingPools.append(lendable)
            else:
                continue
    # Get utilization rates
    for pool in lendingPools:
        totalSupply = pool.totalSupply()
        availableLiq = interface.ERC20(wftm).balanceOf(pool)
        totalDeposited = (totalSupply * pool.exchangeRateLast()) / 1e18
        utilization = ((totalDeposited - availableLiq) / totalDeposited) * 100
        print(
            f"""TSupply : {bcolors.OKBLUE}{totalDeposited/1e18} FTM {bcolors.ENDC}
                Avail :   {bcolors.OKBLUE}{(totalDeposited - availableLiq)/1e18} FTM {bcolors.ENDC} 
                Util:     {bcolors.OKGREEN}{utilization}%{bcolors.ENDC}"""
        )
        #Only look for high utilization lending pools
        if utilization > 60:
            poolData.append(
                [pool.address, utilization, totalDeposited / 1e18, availableLiq / 1e18]
            )
    # organize based on utilization
    poolData.sort(key=takeSecond, reverse=True)
    print(poolData)
