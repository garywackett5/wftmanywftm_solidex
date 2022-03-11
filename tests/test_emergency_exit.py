import math
import brownie
from brownie import Contract
from brownie import config

# test passes as of 21-06-26
def test_emergency_exit(
    gov,
    token,
    vault,
    whale,
    strategy,
    chain,
    amount,
):
    ## deposit to the vault after approving
    aidrop = 10*1e18
    startingWhale = token.balanceOf(whale)-aidrop
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # simulate 1 day of earnings
    chain.sleep(86400)
    chain.mine(1)
    chain.sleep(1)
    token.transfer(vault, aidrop, {"from": whale})
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set emergency and exit, then confirm that the strategy has no funds
    strategy.setEmergencyExit({"from": gov})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)
    assert strategy.estimatedTotalAssets() == 0

    # simulate a day of waiting for share price to bump back up
    chain.sleep(86400)
    chain.mine(1)

    # withdraw and confirm we made money
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) >= startingWhale


def test_emergency_exit_with_profit(
    gov,
    token,
    vault,
    whale,
    strategy,
    chain,
    amount,
):
    ## deposit to the vault after approving. turn off health check since we're doing weird shit
    strategy.setDoHealthCheck(False, {"from": gov})
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # simulate 1 day of earnings
    chain.sleep(86400)
    chain.mine(1)
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # set emergency and exit, then confirm that the strategy has no funds
    donation = amount
    token.transfer(strategy, donation, {"from": whale})
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.setEmergencyExit({"from": gov})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)
    assert strategy.estimatedTotalAssets() == 0

    # simulate a day of waiting for share price to bump back up
    chain.sleep(86400)
    chain.mine(1)

    # withdraw and confirm we made money
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) + donation >= startingWhale


