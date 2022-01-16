import brownie
from brownie import Contract
from brownie import config
import math

# test passes as of 21-06-26
def test_emergency_shutdown_from_vault(
    gov,
    token,
    vault,
    whale,
    strategy,
    chain,
    amount,
    dust,
):
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # simulate one day of earnings
    chain.sleep(86400)
    chain.mine(1)

    # set emergency and exit, then confirm that the strategy has no funds
    vault.setEmergencyShutdown(True, {"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # in emergency shutdown, debtOutstanding is set to the full debt balance of the strategy, so this harvest will be removing all funds
    tx = strategy.harvest({"from": gov})
    chain.sleep(1)

    # since we earn yield every block, and converting to another token, it's hard to get rid of all of it
    assert strategy.estimatedTotalAssets() < dust
    print(
        "This is how much we have leftover:",
        strategy.estimatedTotalAssets() / (10 ** token.decimals()),
    )

    # simulate a day of waiting for share price to bump back up
    chain.sleep(86400)
    chain.mine(1)

    # withdraw and confirm we made money
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) >= startingWhale
