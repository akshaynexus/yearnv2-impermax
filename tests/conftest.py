import pytest
from brownie import config


@pytest.fixture
def andre(accounts):
    # Andre, giver of tokens, and maker of yield
    yield accounts[0]


@pytest.fixture
def gov(accounts):
    # yearn multis... I mean YFI governance. I swear!
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    # YFI Whale, probably
    yield accounts[2]


@pytest.fixture
def strategist(accounts):
    # You! Our new Strategist!
    yield accounts[3]


@pytest.fixture
def keeper(accounts):
    # This is our trusty bot!
    yield accounts[4]


@pytest.fixture
def bob(accounts):
    yield accounts[5]


@pytest.fixture
def alice(accounts):
    yield accounts[6]


@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract


@pytest.fixture
def currency(interface):
    # this one is curvesteth
    yield interface.ERC20("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")


@pytest.fixture
def whale(accounts):
    # Binance 7,Has alot of 1INCH
    yield accounts.at("0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503", force=True)


@pytest.fixture
def vault(pm, gov, rewards, guardian, currency):
    Vault = pm(config["dependencies"][0]).Vault
    vault = gov.deploy(Vault)
    vault.initialize(currency, gov, rewards, "", "", guardian)
    vault.setManagementFee(0, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy):
    strategy = strategist.deploy(Strategy, vault, 2)
    strategy.setKeeper(keeper)
    yield strategy
