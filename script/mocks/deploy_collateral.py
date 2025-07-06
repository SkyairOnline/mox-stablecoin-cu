from src.mocks import mock_token
from moccasin.boa_tools import VyperContract

def deploy_collateral() -> VyperContract:
    return mock_token()

def moccasin_main() -> VyperContract:
    return deploy_collateral()