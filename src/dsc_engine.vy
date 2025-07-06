# pragma version 0.4.3

"""
@license MIT
@author Aldo Surya Ongko
@title Decentralized Stable coin Engine
@notice
    Collateral: Exogenous (WETH, WBTC, etc...)
    Minting (Stability) Mechanism: Decentralized (Algorithmic)
    Value (Relative Stability): Anchored (Pegged to USD)
    Collateral Type: Crypto (ERC20 Tokens)
"""
from interfaces import i_decentralized_stable_coin
from interfaces import AggregatorV3Interface
from ethereum.ercs import IERC20
from src import oracle_lib

# State Variables
DSC: public(immutable(i_decentralized_stable_coin))
COLLATERAL_TOKENS: public(immutable(address[2]))  # WETH, WBTC
ADDITIONAL_FEED_PRECISION: public(constant(uint256)) = 1 * (10 ** 10)  # To adjust for price feed decimals
PRECISION: public(constant(uint256)) = 1 * (10 ** 18)  # For token amounts
LIQUIDATION_THRESHOLD: public(constant(uint256)) = 50
LIQUIDATION_PRECISION: public(constant(uint256)) = 100
LIQUIDATION_BONUS: public(constant(uint256)) = 10  # 10% bonus for liquidators
MIN_HEALTH_FACTOR: public(constant(uint256)) = 1 * (10 ** 18)  # Minimum health factor to avoid liquidation

# Storage
token_to_price_feed: public(HashMap[address, address])  # Maps token address to price feed address
user_to_token_to_amount_deposited: public(HashMap[address, HashMap[address, uint256]])  # Maps user address to token address to amount deposited
user_to_dsc_minted: public(HashMap[address, uint256])  # Maps user address to amount of DSC minted

# Event
event CollateralDeposited:
    user: indexed(address)
    amount: indexed(uint256)

event CollateralRedeemed:
    token: indexed(address)
    amount: indexed(uint256)
    _from: address
    _to: address

# External Functions
@deploy
def __init__(
    token_address: address[2],
    price_feed_address: address[2],
    dsc_address: address,
):
    """
    @notice we have two collateral token types: ETH and WBTC
    """
    DSC = i_decentralized_stable_coin(dsc_address)
    COLLATERAL_TOKENS = token_address
    self.token_to_price_feed[token_address[0]] = price_feed_address[0]  # WETH
    self.token_to_price_feed[token_address[1]] = price_feed_address[1]  # WBTC

@external
def deposit_collateral(token_collateral_address: address, amount_collateral: uint256):
    self._deposit_collateral(token_collateral_address, amount_collateral)

@external
def deposit_and_mint(token_collateral: address, amount_collateral: uint256, amount_dsc_to_mint: uint256):
    """
    @notice Deposit collateral and mint DSC in one transaction
    """
    self._deposit_collateral(token_collateral, amount_collateral)
    self._mint_dsc(amount_dsc_to_mint)

@external
def mint_dsc(amount: uint256):
    self._mint_dsc(amount)

@external
def redeem_collateral(token_collateral_address: address, amount_collateral: uint256):
    self._redeem_collateral(token_collateral_address, amount_collateral, msg.sender, msg.sender)
    self._revert_if_health_factor_broken(msg.sender)

@external
def redeem_for_dsc(token_collateral: address, amount_collateral: uint256, amount_dsc: uint256):
    self._burn_dsc(amount_dsc, msg.sender, msg.sender)
    self._redeem_collateral(token_collateral, amount_collateral, msg.sender, msg.sender)
    self._revert_if_health_factor_broken(msg.sender)

@external
def burn_dsc(amount: uint256):
    self._burn_dsc(amount, msg.sender, msg.sender)
    self._revert_if_health_factor_broken(msg.sender)

@external
def liquidate(collateral: address, user: address, debt_to_cover: uint256):
    """
    1. Check if their health factor is bad
    2. Cover their debt, by us burning our DSC, but reducint their DSC minted
    3. We will take their collateral
    """
    assert debt_to_cover > 0, "DSCEngine: Needs more than zero"
    starting_health_factor: uint256 = self._health_factor(user)
    assert starting_health_factor < MIN_HEALTH_FACTOR, "DSCEngine: Health factor is good"

    token_amount_from_debt_covered: uint256 = self._get_token_amount_from_usd(collateral, debt_to_cover)
    bonus_collateral: uint256 = (token_amount_from_debt_covered * LIQUIDATION_BONUS) // LIQUIDATION_PRECISION

    self._redeem_collateral(
        collateral,
        token_amount_from_debt_covered + bonus_collateral,
        user,
        msg.sender,  # Liquidator gets the collateral
    )
    self._burn_dsc(debt_to_cover, user, msg.sender)  # Liquidator burns the DSC

    ending_health_factor: uint256 = self._health_factor(user)
    assert ending_health_factor >= starting_health_factor, "DSCEngine: Didn't improve health factor"
    self._revert_if_health_factor_broken(msg.sender)

# Pure and View External Functions
@external
@view
def health_factor(user: address) -> uint256:
    return self._health_factor(user)


@external
@pure
def calculate_health_factor(
    total_dsc_minted: uint256, collateral_value_in_usd: uint256
) -> uint256:
    return self._calculate_health_factor(
        total_dsc_minted, collateral_value_in_usd
    )


@external
@view
def get_account_information(user: address) -> (uint256, uint256):
    return self._get_account_information(user)


@external
@view
def get_usd_value(token: address, amount: uint256) -> uint256:
    return self._get_usd_value(token, amount)


@external
@view
def get_collateral_balance_of_user(user: address, token: address) -> uint256:
    return self.user_to_token_to_amount_deposited[user][token]


@external
@view
def get_account_collateral_value(user: address) -> uint256:
    return self._get_account_collateral_value(user)


@external
@view
def get_token_amount_from_usd(
    token: address, usd_amount_in_wei: uint256
) -> uint256:
    return self._get_token_amount_from_usd(token, usd_amount_in_wei)


@external
@view
def get_collateral_tokens() -> address[2]:
    return COLLATERAL_TOKENS

# Internal Functions
@internal
def _deposit_collateral(token_collateral_address: address, amount_collateral: uint256):
    # Checks
    assert amount_collateral > 0, "DSCEngine: Needs more than zero"
    assert self.token_to_price_feed[token_collateral_address] != empty(address), "DSCEngine: Token not supported"

    # Effects (internal)
    self.user_to_token_to_amount_deposited[msg.sender][token_collateral_address] += amount_collateral
    log CollateralDeposited(user=msg.sender, amount=amount_collateral)

    # Interactions (External)
    success: bool = extcall IERC20(token_collateral_address).transferFrom(
        msg.sender,
        self,
        amount_collateral,
    )
    assert success, "DSCEngine: Transfer failed"

@internal
def _redeem_collateral(token_collateral_address: address, amount_collateral: uint256, _from: address, _to: address):
    self.user_to_token_to_amount_deposited[_from][token_collateral_address] -= amount_collateral
    log CollateralRedeemed(
        token=token_collateral_address,
        amount=amount_collateral,
        _from=_from,
        _to=_to,
    )
    success: bool = extcall IERC20(token_collateral_address).transfer(
        _to,
        amount_collateral,
    )
    assert success, "DSCEngine: Transfer failed"

@internal
def _mint_dsc(amount_dsc_to_mint: uint256):
    assert amount_dsc_to_mint > 0, "DSCEngine: Needs more than zero"
    self.user_to_dsc_minted[msg.sender] += amount_dsc_to_mint
    self._revert_if_health_factor_broken(msg.sender)
    extcall DSC.mint(
        msg.sender,
        amount_dsc_to_mint,
    )

@internal
def _revert_if_health_factor_broken(user: address):
    user_health_factor: uint256 = self._health_factor(user)
    assert user_health_factor >= MIN_HEALTH_FACTOR, "DSCEngine: Health factor is broken"

@internal
def _burn_dsc(amount: uint256, on_behalf_of: address, dsc_from: address):
    self.user_to_dsc_minted[on_behalf_of] -= amount
    extcall DSC.burn_from(
        dsc_from,
        amount,
    )

# pure and view Internal Functions

@internal
@view
def _get_account_information(user: address) -> (uint256, uint256):
    """
    @notice Returns the amount of DSC minted, collateral value
    """
    total_dsc_minted: uint256 = self.user_to_dsc_minted[user]
    collateral_value_in_usd: uint256 = self._get_account_collateral_value(user)
    return total_dsc_minted, collateral_value_in_usd


@internal
@view
def _health_factor(user: address) -> uint256:
    total_dsc_minted: uint256 = 0
    total_collateral_value_usd: uint256 = 0
    total_dsc_minted, total_collateral_value_usd = self._get_account_information(user)
    return self._calculate_health_factor(total_dsc_minted, total_collateral_value_usd)

@internal
@view
def _get_usd_value(token: address, amount: uint256) -> uint256:
    price_feed: AggregatorV3Interface = AggregatorV3Interface(
        self.token_to_price_feed[token]
    )
    round_id: uint80 = 0
    price: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    (
        round_id, price, started_at, updated_at, answered_in_round
    ) = oracle_lib._stale_check_latest_round_data(price_feed.address)
    return (
        (convert(price, uint256) * ADDITIONAL_FEED_PRECISION) * amount
    ) // PRECISION


@internal
@pure
def _calculate_health_factor(total_dsc_minted: uint256, total_collateral_value_usd: uint256) -> uint256:
    if total_dsc_minted == 0:
        return max_value(uint256)
    collateral_adjusted_for_threshold: uint256 = (total_collateral_value_usd * LIQUIDATION_THRESHOLD) // LIQUIDATION_PRECISION
    return (collateral_adjusted_for_threshold * PRECISION) // total_dsc_minted

@internal
@view
def _get_account_collateral_value(user: address) -> uint256:
    """
    @notice Returns the total collateral value for a user
    """
    total_collateral_value_usd: uint256 = 0
    for token_address: address in COLLATERAL_TOKENS:
        amount: uint256 = self.user_to_token_to_amount_deposited[user][token_address]
        total_collateral_value_usd += self._get_usd_value(token_address, amount)
    return total_collateral_value_usd


@internal
@view
def _get_token_amount_from_usd(
    token: address, usd_amount_in_wei: uint256
) -> uint256:
    price_feed: AggregatorV3Interface = AggregatorV3Interface(
        self.token_to_price_feed[token]
    )
    round_id: uint80 = 0
    price: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    (
        round_id, price, started_at, updated_at, answered_in_round
    ) = oracle_lib._stale_check_latest_round_data(price_feed.address)
    return (
        (usd_amount_in_wei * PRECISION) // (
            convert(price, uint256) * ADDITIONAL_FEED_PRECISION
        )
    )