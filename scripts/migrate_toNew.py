from brownie import Contract, accounts, interface, Strategy, chain


def main():
    oldStrat = Contract("0x1922Fde0C9f09cD1AEAe20C6021a2c18a9CBD589")
    vault = Contract(oldStrat.vault())
    gov = accounts.at(vault.governance(), force=True)
    assets = oldStrat.estimatedTotalAssets()
    poolConf = [
        ["0x9cDED654472788a143C2285A6b2a580392510688", 1102],  # WFTM-YFI
        ["0xDf79EA5d777F28cAb9fD42ACda6208a228c71B59", 1095],  # WFTM-LINK
        ["0xF2D3AE45F8775bA0a729dF47210164F921Edc306", 1082],  # WFTM-LINK
        ["0x37F6Cf24bA9E781344Ae4aC8923d9A0A3910bc64", 1076],  # WFTM-SUSHI
        ["0x0c60dbD5b78d1488F9f71163E598d90f8EDE55E7", 1064],  # WFTM-WOOFY
        ["0x4e4a8AE836cBE9576113706e166ae1194A7113E6", 1053],  # WFTM-MIM
        ["0x00Fb23C7169E0378a63D9cFE50Ef40f944653c69", 1035],  # WFTM-SUSHI
        ["0xB566727F4edF30bA13939E304d828e30d4063C59", 960],  # WFTM-MIM
        ["0xD05f23002f6d09Cf7b643B69F171cc2A3EAcd0b3", 769],  # WFTM-BOO
        ["0x5dd76071F7b5F4599d4F2B7c08641843B746ace9", 764],  # WFTM-TAROT
    ]
    newStrat = Strategy.deploy(vault, poolConf, {"from": gov})
    for pool in poolConf:
        pToken = interface.IERC20(pool[0])
        oldStrat.sweep(pToken, {"from": gov})
        # send small dust back or migrate doesnt work
        pToken.transfer(oldStrat, 100, {"from": gov})
        pToken.transfer(newStrat, pToken.balanceOf(gov), {"from": gov})
    vault.migrateStrategy(oldStrat, newStrat, {"from": gov})
    print(assets / 1e18)
    print(newStrat.estimatedTotalAssets() / 1e18)
    # Make sure harvest works
    newStrat.harvest({"from": gov})
    # Make sure rebalancing works
    for i in range(2):
        debugStratData(newStrat, "Before")
        newStrat.harvest({"from": gov})
        newStrat.rebalance(newStrat.estimatedTotalAssets() / 10, {"from": gov})
        newStrat.harvest({"from": gov})

        debugStratData(newStrat, "After")

    assets = newStrat.estimatedTotalAssets()
    sleepAndHarvest(5, newStrat, gov)
    sleepAndHarvest(5, newStrat, gov)
    newassets = newStrat.estimatedTotalAssets()
    diff = newassets - assets
    print(diff / 1e18)
    print(diff / 10 / 1e18)


def sleepAndHarvest(times, strat, gov):
    for i in range(times):
        debugStratData(strat, "Before harvest" + str(i))
        chain.sleep(17280)
        chain.mine(1)
        strat.harvest({"from": gov})
        debugStratData(strat, "After harvest" + str(i))


# Used to debug strategy balance data
def debugStratData(strategy, msg):
    print(msg)
    print("Total assets " + str(strategy.estimatedTotalAssets() / 1e18))
    print("ftm Balance " + str(strategy.balanceOfWant() / 1e18))
    print("Stake balance " + str(strategy.balanceOfStake() / 1e18))
    print("Pending reward " + str(strategy.pendingInterest() / 1e18))
