# pragma version 0.4.3

"""
@license MIT
@author Aldo Surya Ongko
@title Decentralized Stable coin
@dev Follows the ERC20 token standard.
"""

from snekmate.tokens import erc20
from snekmate.auth import ownable
from interfaces import i_decentralized_stable_coin

implements: i_decentralized_stable_coin
initializes: ownable
initializes: erc20[ownable := ownable]

exports: (
    erc20.IERC20,
    erc20.burn_from,
    erc20.mint,
    erc20.set_minter,
    ownable.owner,
    ownable.transfer_ownership,
)

NAME: constant(String[25]) = "Decentralized Stable Coin"
SYMBOL: constant(String[5]) = "DSC"
DECIMALS: constant(uint8) = 18
EIP_712_VERSION: constant(String[20]) = "1"

# Deploy
@deploy
def __init__():
    ownable.__init__()
    erc20.__init__(NAME, SYMBOL, DECIMALS, NAME, EIP_712_VERSION)

