import pytest
from brownie import config, Wei, Contract

# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture(scope="module")
def whale(accounts):
    # Totally in it for the tech
    # Update this with a large holder of your want token (the largest EOA holder of LP)
    whale = accounts.at("0x39B3bd37208CBaDE74D0fcBDBb12D606295b430a", force=True)
    yield whale


# this is the amount of funds we have our whale deposit. adjust this as needed based on their wallet balance
@pytest.fixture(scope="module")
def amount(token):
    amount = 100_000 * (10 ** token.decimals())
    yield amount


# this is the name we want to give our strategy
@pytest.fixture(scope="module")
def strategy_name():
    strategy_name = "StrategyTarotLenderWFTM"
    yield strategy_name


@pytest.fixture(scope="module")
def healthCheck():
    yield Contract("0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0")


# Define relevant tokens and contracts in this section
@pytest.fixture(scope="module")
def token():
    # this should be the address of the ERC-20 used by the strategy/vault
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
    yield Contract(token_address)


# this is the amount of funds we are okay leaving in our strategy due to unrealized profit or conversion between bTokens
@pytest.fixture(scope="module")
def dust(token):
    dust = 0.1 * (10 ** token.decimals())
    yield dust


# These are the pools we will lend to
@pytest.fixture(scope="module")
def pools():
    pools = [  # "0x5dd76071F7b5F4599d4F2B7c08641843B746ace9",  # FTM-TAROT
        "0x93a97db4fEA1d053C31f0B658b0B87f4b38e105d",  # FTM-SPIRIT Spirit
        "0x6e11aaD63d11234024eFB6f7Be345d1d5b8a8f38",  # USDC-FTM Spirit
        "0x5B80b6e16147bc339e22296184F151262657A327",  # FTM-CRV Spooky
        "0xFf0BC3c7df0c247E5ce1eA220c7095cE1B6Dc745",  # FTM-USDC Spooky
    ]
    yield pools


# zero address
@pytest.fixture(scope="module")
def zero_address():
    zero_address = "0x0000000000000000000000000000000000000000"
    yield zero_address


@pytest.fixture(scope="module")
def farmed():
    yield Contract("0x34D33dc8Ac6f1650D94A7E9A972B47044217600b")


# Define any accounts in this section
# for live testing, governance is the strategist MS; we will update this before we endorse
# normal gov is ychad, 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52
@pytest.fixture(scope="module")
def gov(accounts):
    yield accounts.at("0xC0E2830724C946a6748dDFE09753613cd38f6767", force=True)


@pytest.fixture(scope="module")
def strategist_ms(accounts):
    # like governance, but better
    yield accounts.at("0x72a34AbafAB09b15E7191822A679f28E067C4a16", force=True)


@pytest.fixture(scope="module")
def keeper(accounts):
    yield accounts.at("0xBedf3Cf16ba1FcE6c3B751903Cf77E51d51E05b8", force=True)


@pytest.fixture(scope="module")
def rewards(accounts):
    yield accounts.at("0xBedf3Cf16ba1FcE6c3B751903Cf77E51d51E05b8", force=True)


@pytest.fixture(scope="module")
def guardian(accounts):
    yield accounts[2]


@pytest.fixture(scope="module")
def management(accounts):
    yield accounts[3]


@pytest.fixture(scope="module")
def strategist(accounts):
    yield accounts.at("0xBedf3Cf16ba1FcE6c3B751903Cf77E51d51E05b8", force=True)


@pytest.fixture(scope="module")
def other_vault_strategy():
    # this is fantom curve vault strat
    other_vault_strategy = "0xcF3b91D83cD5FE15269E6461098fDa7d69138570"
    yield Contract(other_vault_strategy)


# # list any existing strategies here
# @pytest.fixture(scope="module")
# def LiveStrategy_1():
#     yield Contract("0xC1810aa7F733269C39D640f240555d0A4ebF4264")


# use this if you need to deploy the vault
@pytest.fixture(scope="function")
def vault(pm, gov, rewards, guardian, management, token, chain):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    chain.sleep(1)
    yield vault


# use this if your vault is already deployed
# @pytest.fixture(scope="function")
# def vault(pm, gov, rewards, guardian, management, token, chain):
#     vault = Contract("0x497590d2d57f05cf8B42A36062fA53eBAe283498")
#     yield vault


# replace the first value with the name of your strategy
@pytest.fixture(scope="function")
def strategy(
    StrategyImperamaxLender,
    strategist,
    keeper,
    vault,
    gov,
    guardian,
    token,
    healthCheck,
    chain,
    strategy_name,
    strategist_ms,
    pools,
):
    # make sure to include all constructor parameters needed here
    strategy = strategist.deploy(
        StrategyImperamaxLender,
        vault,
        pools,
        strategy_name,
    )
    strategy.setKeeper(keeper, {"from": gov})
    # set our management fee to zero so it doesn't mess with our profit checking
    vault.setManagementFee(0, {"from": gov})
    # add our new strategy
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    strategy.setHealthCheck(healthCheck, {"from": gov})
    strategy.setDoHealthCheck(True, {"from": gov})

    # set our custom allocations (use this and comment it out to test 1 vs 4 pools allocated to)
    new_allocations = [2500, 2500, 2500, 2500]
    strategy.manuallySetAllocations(new_allocations, {"from": gov})
    yield strategy


# use this if your strategy is already deployed
# @pytest.fixture(scope="function")
# def strategy():
#     # parameters for this are: strategy, vault, max deposit, minTimePerInvest, slippage protection (10000 = 100% slippage allowed),
#     strategy = Contract("0xC1810aa7F733269C39D640f240555d0A4ebF4264")
#     yield strategy
