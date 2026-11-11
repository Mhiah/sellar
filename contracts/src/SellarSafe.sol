// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITroveManager, IPriceFeed} from "./interfaces/IMezo.sol";
import {SellarShield} from "./SellarShield.sol";

/// @title SellarSafe
/// @notice The four-eyes rule for AI agents, enforced on Mezo. An owner keeps MUSD here and names an
/// agent key. The agent can only ask to pay. A payment goes out on its own only when it passes every
/// rule the owner set; anything else waits as a hold that only the owner can release.
///
/// Rules checked on every request:
///  - the payee is on the owner's trusted list, and has been for at least the cooldown
///  - the amount is within the per-payment and daily limits
///  - the payee is not on the SellarShield scam list
///  - if the owner set a floor, the owner's Mezo loan is above that collateral ratio
///
/// Every payment carries a small fee to the SellarShield cover fund and gets a receipt there.
contract SellarSafe is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Account {
        address agent;
        bool frozen;
        uint64 cooldown; // seconds a payee must be trusted before the agent can pay it unattended
        uint64 day; // day number of spentToday
        uint128 perPayment;
        uint128 perDay;
        uint128 spentToday;
        uint256 balance;
        uint256 minIcr; // 0 = off. 1e18 = 100%. Hold payments while the owner's loan is below this.
    }

    enum HoldState {
        None,
        Pending,
        Paid,
        Rejected
    }

    struct Hold {
        address owner;
        address to;
        uint128 amount;
        uint64 createdAt;
        uint32 reasons;
        HoldState state;
        bytes32 memo;
    }

    // Reasons a request was held (bit flags).
    uint32 public constant R_UNKNOWN_PAYEE = 1;
    uint32 public constant R_COOLDOWN = 2;
    uint32 public constant R_OVER_PAYMENT_LIMIT = 4;
    uint32 public constant R_OVER_DAILY_LIMIT = 8;
    uint32 public constant R_FLAGGED = 16;
    uint32 public constant R_CONFIRMED_SCAM = 32;
    uint32 public constant R_LOW_LOAN_HEALTH = 64;
    uint32 public constant R_AGENT_ESCALATED = 128;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 100;
    uint8 internal constant TROVE_ACTIVE = 1;

    IERC20 public immutable musd;
    SellarShield public immutable shield;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    /// Cover fee on each payment, in basis points. Fixed at deployment.
    uint256 public immutable feeBps;
    /// How long the owner has to approve a hold.
    uint256 public immutable holdTtl;

    mapping(address owner => Account) public accounts;
    mapping(address owner => mapping(address payee => uint64 trustedAt)) public trustedAt;
    Hold[] public holds;
    mapping(address owner => uint256[]) private _holdsOf;

    event Deposited(address indexed owner, address indexed from, uint256 amount);
    event Withdrawn(address indexed owner, uint256 amount);
    event Configured(address indexed owner, address agent, uint128 perPayment, uint128 perDay, uint64 cooldown, uint256 minIcr);
    event Trusted(address indexed owner, address indexed payee);
    event Untrusted(address indexed owner, address indexed payee);
    event Frozen(address indexed owner, address indexed by);
    event Unfrozen(address indexed owner);
    event Held(uint256 indexed holdId, address indexed owner, address indexed to, uint256 amount, uint32 reasons, bytes32 memo);
    event Approved(uint256 indexed holdId);
    event Rejected(uint256 indexed holdId);
    event Paid(address indexed owner, address indexed to, uint256 amount, uint256 fee, uint256 receiptId);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error NotAgent();
    error NotOwner();
    error AccountFrozen();
    error InsufficientBalance();
    error PayeeFlagged();
    error NotPending();
    error HoldExpired();
    error ConfirmedScam();
    error FlaggedSinceHold();

    constructor(
        IERC20 musd_,
        SellarShield shield_,
        ITroveManager troveManager_,
        IPriceFeed priceFeed_,
        uint256 feeBps_,
        uint256 holdTtl_
    ) {
        if (
            address(musd_) == address(0) || address(shield_) == address(0) || address(troveManager_) == address(0)
                || address(priceFeed_) == address(0)
        ) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        musd = musd_;
        shield = shield_;
        troveManager = troveManager_;
        priceFeed = priceFeed_;
        feeBps = feeBps_;
        holdTtl = holdTtl_;
    }

    // ---------------------------------------------------------------- owner

    /// @notice Add MUSD to `owner`'s account. Anyone can fund an account.
    function deposit(address owner, uint256 amount) external nonReentrant {
        if (owner == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        accounts[owner].balance += amount;
        musd.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(owner, msg.sender, amount);
    }

    /// @notice Take MUSD out. Only the owner, at any time, frozen or not.
    function withdraw(uint256 amount) external nonReentrant {
        Account storage a = accounts[msg.sender];
        if (amount > a.balance) revert InsufficientBalance();
        a.balance -= amount;
        musd.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Set the agent key and the rules for the caller's account.
    /// @param minIcr Collateral ratio floor for the owner's Mezo loan (1e18 = 100%), or 0 to turn it off.
    function configure(address agent, uint128 perPayment, uint128 perDay, uint64 cooldown, uint256 minIcr) external {
        Account storage a = accounts[msg.sender];
        a.agent = agent;
        a.perPayment = perPayment;
        a.perDay = perDay;
        a.cooldown = cooldown;
        a.minIcr = minIcr;
        emit Configured(msg.sender, agent, perPayment, perDay, cooldown, minIcr);
    }

    /// @notice Add a trusted payee. Refused if the address is on the scam list.
    function trust(address payee) external {
        if (payee == address(0)) revert ZeroAddress();
        SellarShield.Status s = shield.statusOf(payee);
        if (s == SellarShield.Status.Flagged || s == SellarShield.Status.Confirmed) revert PayeeFlagged();
        trustedAt[msg.sender][payee] = uint64(block.timestamp);
        emit Trusted(msg.sender, payee);
    }

    function untrust(address payee) external {
        delete trustedAt[msg.sender][payee];
        emit Untrusted(msg.sender, payee);
    }

    /// @notice Stop every agent payment and approval. The owner or the agent can freeze.
    function freeze(address owner) external {
        Account storage a = accounts[owner];
        if (msg.sender != owner && msg.sender != a.agent) revert NotOwner();
        a.frozen = true;
        emit Frozen(owner, msg.sender);
    }

    /// @notice Only the owner can unfreeze.
    function unfreeze() external {
        accounts[msg.sender].frozen = false;
        emit Unfrozen(msg.sender);
    }

    /// @notice Release a held payment. Pays exactly what was held, once.
    /// @param acknowledgeFlag Must be true to release a payment to an address that is flagged now.
    function approve(uint256 holdId, bool acknowledgeFlag) external nonReentrant {
        Hold storage h = holds[holdId];
        if (h.owner != msg.sender) revert NotOwner();
        if (h.state != HoldState.Pending) revert NotPending();
        if (block.timestamp > uint256(h.createdAt) + holdTtl) revert HoldExpired();
        if (accounts[msg.sender].frozen) revert AccountFrozen();
        SellarShield.Status s = shield.statusOf(h.to);
        if (s == SellarShield.Status.Confirmed) revert ConfirmedScam();
        if (s == SellarShield.Status.Flagged && !acknowledgeFlag) revert FlaggedSinceHold();
        h.state = HoldState.Paid;
        emit Approved(holdId);
        // The owner's own release does not use up the agent's daily allowance.
        _pay(msg.sender, h.to, h.amount, false);
    }

    function reject(uint256 holdId) external {
        Hold storage h = holds[holdId];
        if (h.owner != msg.sender) revert NotOwner();
        if (h.state != HoldState.Pending) revert NotPending();
        h.state = HoldState.Rejected;
        emit Rejected(holdId);
    }

    // ---------------------------------------------------------------- agent

    /// @notice Ask to pay `amount` MUSD from `owner`'s account to `to`.
    /// Pays at once if every rule passes. Otherwise records a hold for the owner.
    /// @param memo Free reference, for example the hash of an invoice.
    /// @param escalate The agent (or the guard in front of it) asks for a human even if the rules pass.
    /// @return paid True if the payment went out now.
    /// @return holdId The hold to approve or reject when `paid` is false.
    function request(address owner, address to, uint128 amount, bytes32 memo, bool escalate)
        external
        nonReentrant
        returns (bool paid, uint256 holdId)
    {
        Account storage a = accounts[owner];
        if (msg.sender != a.agent) revert NotAgent();
        if (a.frozen) revert AccountFrozen();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint32 reasons = check(owner, to, amount);
        if (escalate) reasons |= R_AGENT_ESCALATED;
        if (reasons == 0) {
            _pay(owner, to, amount, true);
            return (true, 0);
        }
        holdId = holds.length;
        _holdsOf[owner].push(holdId);
        holds.push(
            Hold({
                owner: owner,
                to: to,
                amount: amount,
                createdAt: uint64(block.timestamp),
                reasons: reasons,
                state: HoldState.Pending,
                memo: memo
            })
        );
        emit Held(holdId, owner, to, amount, reasons, memo);
        return (false, holdId);
    }

    // ---------------------------------------------------------------- views

    /// @notice Dry run: the reasons a request would be held. 0 means it would pay at once.
    function check(address owner, address to, uint256 amount) public view returns (uint32 reasons) {
        Account storage a = accounts[owner];
        uint64 since = trustedAt[owner][to];
        if (since == 0) {
            reasons |= R_UNKNOWN_PAYEE;
        } else if (block.timestamp < uint256(since) + a.cooldown) {
            reasons |= R_COOLDOWN;
        }
        if (amount > a.perPayment) reasons |= R_OVER_PAYMENT_LIMIT;
        if (_spentToday(a) + amount > a.perDay) reasons |= R_OVER_DAILY_LIMIT;

        SellarShield.Status s = shield.statusOf(to);
        if (s == SellarShield.Status.Flagged) reasons |= R_FLAGGED;
        if (s == SellarShield.Status.Confirmed) reasons |= R_CONFIRMED_SCAM;

        if (a.minIcr != 0 && !_loanHealthy(owner, a.minIcr)) reasons |= R_LOW_LOAN_HEALTH;
    }

    /// @notice The owner's Mezo loan: whether one is open and its collateral ratio (1e18 = 100%).
    function loanHealth(address owner) external view returns (bool hasLoan, uint256 icr) {
        if (troveManager.getTroveStatus(owner) != TROVE_ACTIVE) return (false, 0);
        return (true, troveManager.getCurrentICR(owner, priceFeed.fetchPrice()));
    }

    function holdCount() external view returns (uint256) {
        return holds.length;
    }

    function holdCountOf(address owner) external view returns (uint256) {
        return _holdsOf[owner].length;
    }

    /// @notice An owner's hold ids, newest first, `limit` at a time starting `offset` from the newest.
    function holdIdsOf(address owner, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage all = _holdsOf[owner];
        if (offset >= all.length) return new uint256[](0);
        uint256 n = all.length - offset;
        if (n > limit) n = limit;
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = all[all.length - 1 - offset - i];
        }
    }

    function spentToday(address owner) external view returns (uint256) {
        return _spentToday(accounts[owner]);
    }

    // ---------------------------------------------------------------- internal

    function _spentToday(Account storage a) internal view returns (uint256) {
        return a.day == uint64(block.timestamp / 1 days) ? a.spentToday : 0;
    }

    /// No loan means nothing to protect. If Mezo's contracts cannot be read, treat it as unhealthy
    /// so the payment waits for the owner.
    function _loanHealthy(address owner, uint256 minIcr) internal view returns (bool) {
        try troveManager.getTroveStatus(owner) returns (uint8 status) {
            if (status != TROVE_ACTIVE) return true;
        } catch {
            return false;
        }
        try priceFeed.fetchPrice() returns (uint256 price) {
            try troveManager.getCurrentICR(owner, price) returns (uint256 icr) {
                return icr >= minIcr;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function _pay(address owner, address to, uint256 amount, bool countsTowardDailyLimit) internal {
        Account storage a = accounts[owner];
        uint256 fee = (amount * feeBps) / BPS;
        if (amount + fee > a.balance) revert InsufficientBalance();
        a.balance -= amount + fee;

        if (countsTowardDailyLimit) {
            uint64 today = uint64(block.timestamp / 1 days);
            if (a.day != today) {
                a.day = today;
                a.spentToday = 0;
            }
            a.spentToday += uint128(amount);
        }

        musd.safeTransfer(to, amount);
        if (fee > 0) musd.safeTransfer(address(shield), fee);
        uint256 receiptId = shield.recordPayment(owner, to, amount);
        emit Paid(owner, to, amount, fee, receiptId);
    }
}
