import pytest
from brownie import Wei, accounts, chain


def test_shutdown(gov, whale, currency, vault, strategy):
    currency.approve(vault, 2 ** 256 - 1, {"from": gov})

    currency.approve(whale, 2 ** 256 - 1, {"from": whale})
    currency.transferFrom(whale, gov, 40000 * 1e6, {"from": whale})

    vault.setDepositLimit(40000 * 1e6, {"from": gov})
    # Start with 100% of the debt
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})
    # Depositing 80k
    vault.deposit(40000 * 1e6, {"from": gov})
    strategy.harvest()

    vault.revokeStrategy(strategy, {"from": gov})
    strategy.harvest()
    assert vault.strategies(strategy).dict()["totalDebt"] == 0
