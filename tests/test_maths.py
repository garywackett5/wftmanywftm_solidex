import brownie
from brownie import Contract
from brownie import config
import math

# test passes as of 21-06-26


def test_maths(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    amount,
    wftm,
    anyWFTM
):

    lp = '0x5804F6C40f44cF7593F73cf3aa16F7037213A623'
    # test the maths
    wftm_lp = wftm.balanceOf(lp)
    any_wftm_lp = anyWFTM.balanceOf(lp)

    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})

    strategy.harvest({"from": gov})

    print('amount: ', amount)
    print('estimatedTotalAssets', strategy.estimatedTotalAssets())
    assert strategy.estimatedTotalAssets() > amount*.0999
    print('balanceOfWant', strategy.balanceOfWant()/1e18)
    print('balanceOfanyFYM', anyWFTM.balanceOf(strategy)/1e18)
    assert wftm.balanceOf(strategy) < 1e18
    assert anyWFTM.balanceOf(strategy) < 1e18
    staked = strategy.balanceOfLPStaked()
    assert staked > 0
    print('balanceOfLPStaked', strategy.balanceOfLPStaked())
    (value_boo, value_xboo) = strategy.balanceOfConstituents(staked)
    print(strategy.balanceOfConstituents(staked))
