// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Minimal views of Mezo's MUSD protocol contracts used by Sellar.
// Signatures match the official package mezo-org/musd-contracts v1.1.0 (deployments/matsnet and mainnet).

interface IStabilityPool {
    /// Pulls MUSD with transferFrom, so the depositor must approve the pool first.
    function provideToSP(uint256 amount) external;

    /// Reverts while any trove is below the minimum collateral ratio, and when the caller has no deposit.
    /// Sends the caller's accumulated BTC gain along with the MUSD.
    function withdrawFromSP(uint256 amount) external;

    function getCompoundedMUSDDeposit(address depositor) external view returns (uint256);

    function getDepositorCollateralGain(address depositor) external view returns (uint256);
}

interface ITroveManager {
    /// 1 means the trove is active.
    function getTroveStatus(address borrower) external view returns (uint8);

    function getCurrentICR(address borrower, uint256 price) external view returns (uint256);
}

interface IPriceFeed {
    function fetchPrice() external view returns (uint256);
}
