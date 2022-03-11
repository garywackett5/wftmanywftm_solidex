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
    boo,
    xboo
):  

    lp = '0x5804F6C40f44cF7593F73cf3aa16F7037213A623'
    #test the maths
    boo_lp = boo.balanceOf(lp)
    xboo_lp = xboo.balanceOf(lp)
    print('ratio in  lp ', boo_lp/xboo_lp)
    ratio_xboo = xboo.xBOOForBOO(1e18)
    print('ratio in xboo', ratio_xboo/1e18)



    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})

    strategy.harvest({"from": gov})

    print('amount: ', amount)
    print('estimatedTotalAssets', strategy.estimatedTotalAssets())
    assert strategy.estimatedTotalAssets() > amount*.0999
    print('balanceOfWant', strategy.balanceOfWant())
    print('xboo.balanceOf', xboo.balanceOf(strategy))
    assert xboo.balanceOf(strategy) < 1e12
    assert boo.balanceOf(strategy) < 1e12
    staked = strategy.balanceOfLPStaked()
    assert staked >0
    print('balanceOfLPStaked', strategy.balanceOfLPStaked())
    (value_boo, value_xboo) = strategy.balanceOfConstituents(staked)
    assert value_boo > value_xboo

    #dust is all in boo
    assert value_boo + xboo.xBOOForBOO(value_xboo) + boo.balanceOf(strategy) == strategy.estimatedTotalAssets()
    