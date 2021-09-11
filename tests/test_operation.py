import pytest
from brownie import Wei, accounts, chain

# reference code taken from yHegic repo and stecrv strat
# https://github.com/Macarse/yhegic
# https://github.com/Grandthrax/yearnv2_steth_crv_strat
import conftest as config


@pytest.mark.parametrize(config.fixtures, config.params, indirect=True)
@pytest.mark.require_network("ftm-main-fork")
def test_operation(currency, strategy, vault, whale, gov, bob, alice, allocChangeConf):
    # Amount configs
    test_budget = 888000 * 1e18
    approve_amount = 1000000 * 1e18
    deposit_limit = 889000 * 1e18
    bob_deposit = 100000 * 1e18
    alice_deposit = 788000 * 1e18
    currency.approve(whale, approve_amount, {"from": whale})
    currency.transferFrom(whale, gov, test_budget, {"from": whale})

    vault.setDepositLimit(deposit_limit)

    # 100% of the vault's depositLimit
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    currency.approve(gov, approve_amount, {"from": gov})
    currency.transferFrom(gov, bob, bob_deposit, {"from": gov})
    currency.transferFrom(gov, alice, alice_deposit, {"from": gov})
    currency.approve(vault, approve_amount, {"from": bob})
    currency.approve(vault, approve_amount, {"from": alice})

    vault.deposit(bob_deposit, {"from": bob})
    vault.deposit(alice_deposit, {"from": alice})
    # Set locked profit degradation to small amount so pps increases during test
    vault.setLockedProfitDegradation(Wei("1 ether"))
    # Sleep and harvest 5 times,approx for 24 hours
    sleepAndHarvest(5, strategy, gov)
    strategy.changeAllocs(allocChangeConf, {"from": gov})
    sleepAndHarvest(5, strategy, gov)

    # We should have made profit or stayed stagnant (This happens when there is no rewards in 1INCH rewards)
    assert vault.pricePerShare() / 1e18 >= 1
    # Log estimated APR
    growthInShares = vault.pricePerShare() - 1e18
    growthInPercent = (growthInShares / 1e18) * 100
    growthInPercent = growthInPercent * 24
    growthYearly = growthInPercent * 365
    print(f"Yearly APR :{growthYearly}%")
    # Check before pending interest test
    # assert strategy.estimatedTotalAssets() >= vault.totalAssets() + currency.balanceOf(vault)
    # Set debt ratio to lower than 100%
    vault.updateStrategyDebtRatio(strategy, 9_800, {"from": gov})
    chain.sleep(12 * 60 * 60)
    chain.mine(1)
    # Withdraws should not fail
    vault.withdraw(alice_deposit, {"from": alice})
    # Try harvesting again,this should work
    strategy.harvest({"from": gov})
    # check asset balances again after pendinginterestprofit is added on harvest
    # assert strategy.estimatedTotalAssets() >= vault.totalAssets()

    vault.withdraw(bob_deposit, {"from": bob})
    # Check if all users and funds can be withdrawn from vault
    vault.transferFrom(strategy, gov, vault.balanceOf(strategy), {"from": gov})
    vault.withdraw(vault.balanceOf(gov), {"from": gov})
    # Make sure all the funds are taken from vault
    assert vault.totalSupply() == 0
    # # Withdraws should not fail
    # vault.withdraw(alice_deposit, {"from": alice})
    # vault.withdraw(bob_deposit, {"from": bob})

    # Depositors after withdraw should have a profit or gotten the original amount
    assert currency.balanceOf(alice) >= alice_deposit
    assert currency.balanceOf(bob) >= bob_deposit

    # Make sure it isnt less than 1 after depositors withdrew
    assert vault.pricePerShare() / 1e18 >= 1


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
    print("Total assets " + str(strategy.estimatedTotalAssets()))
    print(
        str(strategy.BTokenToWant("0x5dd76071F7b5F4599d4F2B7c08641843B746ace9", 1e18))
    )
    print("ftm Balance " + str(strategy.balanceOfWant()))
    print("Stake balance " + str(strategy.balanceOfStake()))
    print("Pending reward " + str(strategy.pendingInterest()))
