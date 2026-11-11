// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SellarSafe} from "./SellarSafe.sol";

/// @title SellarFaucet
/// @notice Testnet only. Gives each address a small amount of test MUSD, once, straight into its
/// SellarSafe account, so anyone can try Sellar without opening a Mezo loan first.
/// Anyone can refill it by sending it MUSD. Nobody can take MUSD out any other way.
contract SellarFaucet {
    using SafeERC20 for IERC20;

    IERC20 public immutable musd;
    SellarSafe public immutable safe;
    /// MUSD given per address.
    uint256 public immutable amount;

    mapping(address => bool) public claimed;

    event Dripped(address indexed to, uint256 amount);

    error AlreadyClaimed();
    error Empty();

    constructor(IERC20 musd_, SellarSafe safe_, uint256 amount_) {
        musd = musd_;
        safe = safe_;
        amount = amount_;
    }

    /// @notice Put `amount` test MUSD into the caller's SellarSafe account. Once per address.
    function drip() external {
        if (claimed[msg.sender]) revert AlreadyClaimed();
        if (musd.balanceOf(address(this)) < amount) revert Empty();
        claimed[msg.sender] = true;
        musd.forceApprove(address(safe), amount);
        safe.deposit(msg.sender, amount);
        emit Dripped(msg.sender, amount);
    }

    /// @notice How many more addresses the faucet can serve.
    function remaining() external view returns (uint256) {
        return musd.balanceOf(address(this)) / amount;
    }
}
