// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockMUSD is ERC20 {
    constructor() ERC20("Mezo USD", "MUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Follows the behaviour of Mezo's StabilityPool that Sellar relies on:
/// provideToSP pulls with transferFrom, withdrawFromSP reverts with no deposit or while "paused"
/// (a trove under the minimum ratio), deposits can shrink, and BTC gains are sent on any operation.
contract MockStabilityPool {
    IERC20 public immutable musd;
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public gains;
    bool public paused;

    constructor(IERC20 musd_) {
        musd = musd_;
    }

    receive() external payable {}

    function setPaused(bool p) external {
        paused = p;
    }

    /// Simulate a liquidation: burn part of a deposit and credit BTC.
    function liquidate(address depositor, uint256 musdLoss, uint256 btcGain) external {
        deposits[depositor] -= musdLoss;
        gains[depositor] += btcGain;
        musd.transfer(address(0xdead), musdLoss);
    }

    function provideToSP(uint256 amount) external {
        require(amount != 0, "StabilityPool: Amount must be non-zero");
        deposits[msg.sender] += amount;
        require(musd.transferFrom(msg.sender, address(this), amount), "MUSD was not transferred successfully.");
        _sendGain(msg.sender);
    }

    function withdrawFromSP(uint256 amount) external {
        if (amount != 0) require(!paused, "StabilityPool: Cannot withdraw while there are troves with ICR < MCR");
        uint256 d = deposits[msg.sender];
        require(d != 0, "StabilityPool: User must have a non-zero deposit");
        uint256 out = amount < d ? amount : d;
        deposits[msg.sender] = d - out;
        musd.transfer(msg.sender, out);
        _sendGain(msg.sender);
    }

    function getCompoundedMUSDDeposit(address depositor) external view returns (uint256) {
        return deposits[depositor];
    }

    function getDepositorCollateralGain(address depositor) external view returns (uint256) {
        return gains[depositor];
    }

    function _sendGain(address to) internal {
        uint256 g = gains[to];
        if (g == 0) return;
        gains[to] = 0;
        (bool ok,) = to.call{value: g}("");
        require(ok, "Sending BTC failed");
    }
}

contract MockTroveManager {
    mapping(address => uint8) public status;
    mapping(address => uint256) public icr;
    bool public broken;

    function set(address borrower, uint8 status_, uint256 icr_) external {
        status[borrower] = status_;
        icr[borrower] = icr_;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function getTroveStatus(address borrower) external view returns (uint8) {
        require(!broken, "broken");
        return status[borrower];
    }

    function getCurrentICR(address borrower, uint256) external view returns (uint256) {
        require(!broken, "broken");
        return icr[borrower];
    }
}

contract MockPriceFeed {
    uint256 public price = 100_000e18;
    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function fetchPrice() external view returns (uint256) {
        require(!broken, "broken");
        return price;
    }
}
