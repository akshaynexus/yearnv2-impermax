import brownie
from brownie import chain, Contract
import math


# StrategyImperamaxLender.manuallySetAllocations - 87.5%
# customize and check our allocations
def test_custom_allocations(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
):

    ## deposit to the vault after approving
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set our custom allocations
    new_allocations = [2000, 0, 4000, 4000]
    tx = strategy.manuallySetAllocations(new_allocations, {"from": gov})

    # can't set for less than the pools we have or less than 10k total
    new_allocations_wrong = [2000, 2000]
    with brownie.reverts():
        strategy.manuallySetAllocations(new_allocations_wrong, {"from": gov})
    new_allocations_wrong = [2000, 2000, 5000, 500]
    with brownie.reverts():
        strategy.manuallySetAllocations(new_allocations_wrong, {"from": gov})

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # sleep for a day and harvest
    chain.sleep(86400)
    chain.mine(1)
    strategy.harvest({"from": gov})


# StrategyImperamaxLender.addTarotPool - 50.0%
# add a pair
def test_add_pair(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
):

    ## deposit to the vault after approving
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # add a pool
    to_add = "0x5dd76071F7b5F4599d4F2B7c08641843B746ace9"  # FTM-TAROT LP
    strategy.addTarotPool(to_add, {"from": gov})

    # can't add a pool that already exists
    with brownie.reverts():
        strategy.addTarotPool(to_add, {"from": gov})

    # set our custom allocations
    new_allocations = [2000, 2000, 4000, 1000, 1000]
    tx = strategy.manuallySetAllocations(new_allocations, {"from": gov})

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # sleep for a day and harvest
    chain.sleep(86400)
    chain.mine(1)
    strategy.harvest({"from": gov})


# StrategyImperamaxLender.attemptToRemovePool - 46.6%
# remove a pair whenever it doesn't have any locked debt
def test_remove_pair_free(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
):

    ## deposit to the vault after approving
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set our custom allocations
    new_allocations = [2000, 2000, 3000, 3000]
    tx = strategy.manuallySetAllocations(new_allocations, {"from": gov})

    # remove a pair!
    to_remove = "0x5dd76071F7b5F4599d4F2B7c08641843B746ace9"
    strategy.attemptToRemovePool(to_remove, {"from": gov})

    # sleep for a day and harvest
    chain.sleep(86400)
    chain.mine(1)
    strategy.harvest({"from": gov})


# deposit to pools, manually send out free liquidity from these pools to lock our funds up to simulate high utilization
def test_remove_pair_locked(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
    accounts,
):

    ## deposit to the vault after approving
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set our custom allocations
    new_allocations = [2500, 2500, 2500, 2500]
    tx = strategy.manuallySetAllocations(new_allocations, {"from": gov})

    # check pool utilizations
    old_utes = strategy.getEachPoolUtilization({"from": whale})
    print("Pool utilizations at baseline:", old_utes)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our allocations before we do anything stupid:", allocations)

    # have two of the bTokens send away almost all of the free liquidity
    sentient_pool_1 = accounts.at(strategy.pools(0), force=True)
    to_send = token.balanceOf(sentient_pool_1) * 0.9999
    before = token.balanceOf(sentient_pool_1)
    token.transfer(gov, to_send, {"from": sentient_pool_1})
    after = token.balanceOf(sentient_pool_1)
    assert after < before
    print("New balance of pool 1:", after / 1e18)

    # send all of this one
    sentient_pool_2 = accounts.at(strategy.pools(2), force=True)
    to_send = token.balanceOf(sentient_pool_2)
    before = token.balanceOf(sentient_pool_2)
    token.transfer(gov, to_send, {"from": sentient_pool_2})
    after = token.balanceOf(sentient_pool_2)
    assert after < before
    print("New balance of pool 2:", after / 1e18)

    # update the pools
    pool_1 = Contract(strategy.pools(0))
    pool_2 = Contract(strategy.pools(2))
    pool_1.sync({"from": whale})
    pool_2.sync({"from": whale})
    chain.sleep(1)
    chain.mine(1)
    print("We are draining these pools:", pool_1.address, pool_2.address)

    # check our new balances
    new_balance = pool_1.totalBalance() / 1e18
    print(
        "New Pool 1 balance",
    )

    # check pool utilizations, assert that 0 and 2 have gone up
    utes = strategy.getEachPoolUtilization({"from": whale})
    assert utes[2] > old_utes[2]
    assert utes[0] > old_utes[0]
    print("Pool utilizations after force increase:", utes)

    # remove a pair! this one has low liquidity!
    to_remove = strategy.pools(2)
    strategy.attemptToRemovePool(to_remove, {"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("\nThese are our allocations after the first -failed- removal:", allocations)

    # check pool order
    order = strategy.getPools({"from": whale})
    print("Pool order:", order)

    # the pool shouldn't actually be removed
    assert len(strategy.getPools()) == 4

    # check our free want
    new_want = token.balanceOf(strategy)
    print("\nWant after 1 removal:", new_want / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # sleep for a day and harvest, turn off health checks since low liq = high yield
    chain.sleep(86400)
    chain.mine(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    tx = strategy.harvest({"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("\nThese are our allocations after the first harvest:", allocations)

    # check pool order
    order = strategy.getPools({"from": whale})
    print("Pool order:", order)

    # remove a pair! this one should remove just fine. positions 2 and 3 will be our high util pairs
    to_remove = strategy.pools(1)
    strategy.attemptToRemovePool(to_remove, {"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print(
        "\nThese are our allocations after the second removal (that should work):",
        allocations,
    )

    # check pool order
    order = strategy.getPools({"from": whale})
    print("Pool order:", order)

    # the pool should be removed
    assert len(strategy.getPools()) == 3

    # check our free want
    newer_want = token.balanceOf(strategy)
    print("\nWant after 2 removals:", newer_want / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # sleep for a day and harvest, high util pools will automatically move to the back
    chain.sleep(86400)
    chain.mine(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    tx = strategy.harvest({"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("\nThese are our allocations after the second harvest:", allocations)

    # check pool order
    order = strategy.getPools({"from": whale})
    print("Pool order:", order)

    # remove a pair! this is our pair with 0 assets free, the final position.
    to_remove = strategy.pools(2)
    strategy.attemptToRemovePool(to_remove, {"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print(
        "\nThese are our allocations after the third removal, shouldn't work:",
        allocations,
    )

    # check pool order
    order = strategy.getPools({"from": whale})
    print("Pool order:", order)

    # the pool shouldn't actually be removed
    assert len(strategy.getPools()) == 3

    # check our free want
    newest_want = token.balanceOf(strategy)
    print("\nWant after 3 removals:", newest_want / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # sleep for a day and harvest
    chain.sleep(86400)
    chain.mine(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    tx = strategy.harvest({"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("\nThese are our allocations after the harvest:", allocations)

    # check pool order
    order = strategy.getPools({"from": whale})
    print("Pool order:", order)

    pool_1.exchangeRate({"from": whale})
    pool_2.exchangeRate({"from": whale})
    chain.sleep(1)
    chain.mine(1)

    print("\nNew exchange rate:", pool_2.exchangeRateLast() / 1e18)
    print("True exchange rate:", strategy.trueExchangeRate(pool_2.address) / 1e18)

    print("\nVault share price:", vault.pricePerShare() / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)


# StrategyImperamaxLender.manuallySetOrder - 100.0%
# StrategyImperamaxLender.reorderPools - 100.0%
# StrategyImperamaxLender._reorderPools - 93.8%
def test_reorder_pairs(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
):

    ## deposit to the vault after approving
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set our custom allocations
    new_allocations = [2500, 2500, 2500, 2500]
    tx = strategy.manuallySetAllocations(new_allocations, {"from": gov})

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # check pool order
    first = strategy.getPools({"from": whale})
    print("\nPools before any reorder:", first)

    # first, reorder by utilization automatically based on utilization
    strategy.reorderPools({"from": gov})

    # check pool order, and our utilizations
    second = strategy.getPools({"from": whale})
    utes = strategy.getEachPoolUtilization({"from": whale})
    assert utes[2] > utes[1]
    assert utes[1] > utes[0]
    print("\nPools after auto reorder:", second)
    print("Pool utilizations:", utes)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # sleep for a day and harvest
    chain.sleep(86400)
    chain.mine(1)
    strategy.harvest({"from": gov})

    # next, reorder by manual preference
    new_order = [
        "0x6e11aaD63d11234024eFB6f7Be345d1d5b8a8f38",
        "0x5B80b6e16147bc339e22296184F151262657A327",
        "0x93a97db4fEA1d053C31f0B658b0B87f4b38e105d",
        "0xFf0BC3c7df0c247E5ce1eA220c7095cE1B6Dc745",
    ]
    strategy.manuallySetOrder(new_order, {"from": gov})

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # can't reorder with a different length
    new_order_shorter = [
        "0x5B80b6e16147bc339e22296184F151262657A327",
        "0x93a97db4fEA1d053C31f0B658b0B87f4b38e105d",
    ]
    with brownie.reverts():
        strategy.manuallySetOrder(new_order_shorter, {"from": gov})

    # check pool order
    third = strategy.getPools({"from": whale})
    print("\nPools after manual reorder:", third)

    # sleep for a day and harvest
    chain.sleep(86400)
    chain.mine(1)
    strategy.harvest({"from": gov})

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # check that we don't have any free want
    starting_want = token.balanceOf(strategy)
    assert starting_want == 0

    # remove a pair!
    to_remove = strategy.pools(2)
    strategy.attemptToRemovePool(to_remove, {"from": gov})

    # check our free want
    new_want = token.balanceOf(strategy)
    print("\nWant after 1 removal:", new_want / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # remove another pair!
    to_remove = strategy.pools(1)
    strategy.attemptToRemovePool(to_remove, {"from": gov})

    # check our free want
    newer_want = token.balanceOf(strategy)
    print("\nWant after 2 removals:", newer_want / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # remove another pair!
    to_remove = strategy.pools(1)
    strategy.attemptToRemovePool(to_remove, {"from": gov})

    # check our free want
    newer_want = token.balanceOf(strategy)
    print("\nWant after 3 removals:", newer_want / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)

    # reorder pools with only 1 pool
    strategy.reorderPools({"from": gov})

    # turn off reorder
    strategy.setReorder(False, {"from": gov})

    # sleep for a day and harvest
    chain.sleep(86400)
    chain.mine(1)
    tx = strategy.harvest({"from": gov})

    # check our free want
    new_want = token.balanceOf(strategy)
    print("\nWant after 2 removals and harvest:", new_want / 1e18)
    print("Total estimated assets:", strategy.estimatedTotalAssets() / 1e18)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our current allocations:", allocations)


# operate the strategy like normal, but with some of the assets locked in a pool
def test_high_utilization(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
    accounts,
):

    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    print("Starting Whale:", startingWhale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set our custom allocations
    new_allocations = [2500, 2500, 2500, 2500]
    tx = strategy.manuallySetAllocations(new_allocations, {"from": gov})

    # check pool utilizations
    old_utes = strategy.getEachPoolUtilization({"from": whale})
    print("Pool utilizations at baseline:", old_utes)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our allocations before we do anything stupid:", allocations)

    # have two of the bTokens send away almost all of the free liquidity
    sentient_pool_1 = accounts.at(strategy.pools(0), force=True)
    to_send = token.balanceOf(sentient_pool_1) * 0.9999
    before = token.balanceOf(sentient_pool_1)
    token.transfer(gov, to_send, {"from": sentient_pool_1})
    after = token.balanceOf(sentient_pool_1)
    assert after < before
    print("New balance of pool 1:", after / 1e18)

    # send all of this one
    sentient_pool_2 = accounts.at(strategy.pools(2), force=True)
    to_send = token.balanceOf(sentient_pool_2)
    before = token.balanceOf(sentient_pool_2)
    token.transfer(gov, to_send, {"from": sentient_pool_2})
    after = token.balanceOf(sentient_pool_2)
    assert after < before
    print("New balance of pool 2:", after / 1e18)

    # update the pools
    pool_1 = Contract(strategy.pools(0))
    pool_2 = Contract(strategy.pools(2))
    pool_1.sync({"from": whale})
    pool_2.sync({"from": whale})
    chain.sleep(1)
    chain.mine(1)
    print("We are draining these pools:", pool_1.address, pool_2.address)

    # check our new balances
    new_balance = pool_1.totalBalance() / 1e18
    print(
        "New Pool 1 balance",
    )

    # check pool utilizations, assert that 0 and 2 have gone up
    utes = strategy.getEachPoolUtilization({"from": whale})
    assert utes[2] > old_utes[2]
    assert utes[0] > old_utes[0]
    print("Pool utilizations after force increase:", utes)

    # use our emergency withdraw to kill all of our bTokens
    max_uint = 2 ** 256 - 1
    tx = strategy.emergencyWithdraw(max_uint, {"from": gov})

    # try out a full withdrawal, we should have to take a loss
    loss_okay = 10000
    max_uint = 2 ** 256 - 1

    # strategy withdrawals won't accept losses unless vault or strategy is in emergency mode
    with brownie.reverts():
        vault.withdraw(max_uint, whale, loss_okay, {"from": whale})

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    tx = vault.withdraw(max_uint, whale, loss_okay, {"from": whale})
    losses = token.balanceOf(whale) - startingWhale
    print("These are our losses:", losses / (10 ** token.decimals()))


# moved these two to a new test file since in the old one the last test was randomly failing for seemingly no good reasons, hypothesizing that the file was too long?
# test out withdrawing directly from strategy via gov
def test_emergency_withdraw(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
    accounts,
):

    ## deposit to the vault after approving
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set our custom allocations
    new_allocations = [2500, 2500, 2500, 2500]
    strategy.manuallySetAllocations(new_allocations, {"from": gov})

    # check pool utilizations
    old_utes = strategy.getEachPoolUtilization({"from": whale})
    print("Pool utilizations at baseline:", old_utes)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our allocations before we do anything stupid:", allocations)

    # use our emergency withdraw to kill all of our bTokens
    max_uint = 2 ** 256 - 1
    tx = strategy.emergencyWithdraw(max_uint, {"from": gov})

    # check pool utilizations
    new_utes = strategy.getEachPoolUtilization({"from": whale})
    print("Pool utilizations after emergency withdraw:", new_utes)

    # check allocations
    allocations = strategy.getCurrentPoolAllocations({"from": whale})
    print("These are our allocations after withdrawal:", allocations)


# test if we get small losses from rapidly converting in and out of bTokens
def test_deposit_harvest_withdraw(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
    accounts,
):

    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    print("Starting Whale:", startingWhale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    harvest = strategy.harvest({"from": gov})
    chain.sleep(1)

    print(
        "Strategy estimated total assets:",
        strategy.estimatedTotalAssets() / (10 ** token.decimals()),
    )
    tx = vault.withdraw({"from": whale})

    # Seems that sometimes whale loses 1-2 gwei, sometimes doesn't lose anything
    # these losses occur whenever we don't actually update our exchange rates -> no events fire for them, specifically AccrueInterest event
    # additionally, in these cases, the strategy only thinks it has 99,999.999999... WFTM due to conversion,
    # so when it gets this back, it's not a true loss in the strategy's withdrawal call's eyes
    # this appears to only occur when we don't include any chain.sleep or chain.mine around the harvest call
    net = token.balanceOf(whale) - startingWhale
    if net >= 0:
        print("\nThese are our gains, great than or equal to 0:", net, "wei")
    if net < 0:
        print("\nWe lost a few wei, this many:", net * -1, "wei")

    assert net >= 0  # do this to force a revert so we can debug why we reverted
