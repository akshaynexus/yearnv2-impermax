import pytest

import conftest as config


def includeSmallInaccurancy(amount):
    # Allow for 0.001% difference due to calc of btoken required to withdraw amount
    return amount - (amount * 0.00001)


@pytest.mark.parametrize(config.fixtures, config.params, indirect=True)
@pytest.mark.require_network("ftm-main-fork")
def test_migrate(
    currency, Strategy, strategy, chain, vault, whale, gov, strategist, allocChangeConf
):
    debt_ratio = 10_000
    vault.addStrategy(strategy, debt_ratio, 0, 2 ** 256 - 1, 1_000, {"from": gov})

    currency.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(100 * 1e18, {"from": whale})
    strategy.harvest({"from": strategist})

    chain.sleep(12 * 60 * 60)
    chain.mine(1)

    strategy.harvest({"from": strategist})

    chain.sleep(12 * 60 * 60)
    chain.mine(1)
    totalasset_beforemig = strategy.estimatedTotalAssets()
    assert totalasset_beforemig > 0

    strategy2 = strategist.deploy(Strategy, vault, allocChangeConf)
    vault.migrateStrategy(strategy, strategy2, {"from": gov})
    # Check that we got all the funds on migration
    assert strategy2.estimatedTotalAssets() >= includeSmallInaccurancy(
        totalasset_beforemig
    )
