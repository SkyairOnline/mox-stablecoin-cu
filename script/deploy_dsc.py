from moccasin.config import get_active_network
from src import decentralized_stable_coin

def deploy_dsc():
    decentralized_stable_coin_contract = decentralized_stable_coin.deploy()
    active_network = get_active_network()
    # Verify
    if active_network.has_explorer():
        result = active_network.moccasin_verify(decentralized_stable_coin_contract)
        result.wait_for_verification()
    return decentralized_stable_coin_contract


def moccasin_main():
    return deploy_dsc()