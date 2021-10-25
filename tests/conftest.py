import pytest
from brownie import config

fixtures = "currency", "whale", "allocConf", "allocChangeConf"
params = [
    pytest.param(
        "0x21be370d5312f44cb42ce377bc9b8a0cef1a4c83",
        "0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d",
        [
            ["0x5dd76071F7b5F4599d4F2B7c08641843B746ace9"],  # FTM-TARROT LP
            ["0xD05f23002f6d09Cf7b643B69F171cc2A3EAcd0b3"],  # FTM-BOO LP
        ],
        [
            ["0x93a97db4fEA1d053C31f0B658b0B87f4b38e105d"],  # FTM-SPIRIT LP Highest apr
            [
                "0x7A7dd36BCca42952CC1E67BcA1Be44097fF5b644"
            ],  # FTM-BTC LP Spooky 2nd highest apr
            ["0x5dd76071F7b5F4599d4F2B7c08641843B746ace9"],  # FTM-TARROT LP Spooky
            ["0x8C97Dcb6a6b08E8bEECE3D75e918FbC076C094ab"],
            ["0x6e11aaD63d11234024eFB6f7Be345d1d5b8a8f38"],  # USDC-FTM Spirit
            ["0x5B80b6e16147bc339e22296184F151262657A327"],  # FTM-CRV LP Spooky
            ["0xD05f23002f6d09Cf7b643B69F171cc2A3EAcd0b3"],  # FTM-BOO LP
        ],
        id="FTM LP TarrotLender",
    ),
]


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
def currency(request, interface):
    # this one is 3EPS
    yield interface.ERC20(request.param)


@pytest.fixture
def whale(request, accounts):
    acc = accounts.at(request.param, force=True)
    yield acc


@pytest.fixture
def allocConf(request):
    yield request.param


@pytest.fixture
def allocChangeConf(request):
    yield request.param


@pytest.fixture
def vault(pm, gov, rewards, guardian, currency):
    Vault = pm(config["dependencies"][0]).Vault
    vault = gov.deploy(Vault)
    vault.initialize(currency, gov, rewards, "", "", guardian)
    vault.setManagementFee(0, {"from": gov})
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, allocConf):
    strategy = strategist.deploy(Strategy, vault, allocConf)
    strategy.setKeeper(keeper)
    yield strategy
