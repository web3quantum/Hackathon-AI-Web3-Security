pragma solidity ^0.6.0;

abstract contract IOracleRelayer {
    struct CollateralType {
        address orcl;
        uint256 safetyCRatio;
    }

    mapping (bytes32 => CollateralType) public collateralTypes;

    function redemptionPrice() public virtual returns (uint256);
    uint256 public redemptionRate;
}
