from brownie import Strategy, Contract, accounts, config, network, project, web3
from eth_utils import is_checksum_address
import click

def main():

    strategist = accounts.load(click.prompt("Account", type=click.Choice(accounts.load())))

    vault = Contract('0x0fBbf9848D969776a5Eb842EdAfAf29ef4467698')
    print(vault.name())

    strategy_name = "boo_Xboo_veLp_Solidex"


    strategy = strategist.deploy(
        Strategy,
        vault,
        strategy_name
        
    )

    print(strategy)

