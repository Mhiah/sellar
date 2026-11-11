// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStabilityPool} from "./interfaces/IMezo.sol";

/// @title SellarShield
/// @notice A shared scam list and a cover fund for agent payments, both in MUSD.
///
/// Scam list: anyone can report an address by locking a MUSD bond. One report is enough to flag the
/// address, which makes every SellarSafe hold payments to it. A flag is only a warning. The reviewer
/// then confirms the case (bonds returned, reporters share a BTC reward) or dismisses it (bonds are
/// slashed into the cover fund).
///
/// Cover fund: SellarSafe sends a small fee with every payment. If a payee is confirmed as a scam,
/// people who paid it before the first report can claim a refund, up to a cap.
///
/// Mezo: the cover fund keeps a liquid buffer and deposits the rest in Mezo's Stability Pool, where it
/// earns BTC from liquidations. Reporter bonds are never deposited, so they can always be returned.
///
/// Trust model for this version: the reviewer decides confirm or dismiss. The reviewer cannot move
/// funds, change parameters or block bond withdrawals after the resolve timeout.
contract SellarShield is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Flagged,
        Confirmed,
        Dismissed
    }

    struct Case {
        Status status;
        uint32 round; // increases each time a case is dismissed or emptied, so old reports cannot be reused
        uint32 reporters;
        uint64 firstReportAt;
        uint64 resolvedAt;
        uint256 btcPerReporter; // set on confirm
    }

    struct Receipt {
        address payer;
        address payee;
        uint128 amount;
        uint64 paidAt;
        bool claimed;
    }

    uint256 public constant BPS = 10_000;
    /// Share of the cover fund kept liquid; the rest goes to the Stability Pool.
    uint256 public constant BUFFER_BPS = 2_500;
    /// One claim can take at most this share of the fund.
    uint256 public constant MAX_CLAIM_SHARE_BPS = 2_000;
    /// Share of unreserved BTC gains paid to the reporters of a confirmed case.
    uint256 public constant REWARD_BPS = 1_000;

    IERC20 public immutable musd;
    IStabilityPool public immutable stabilityPool;
    /// MUSD locked with each report.
    uint256 public immutable bond;
    /// Largest refund for one payment.
    uint256 public immutable claimCap;
    /// A payment is covered only if its payee is confirmed within this time after the payment.
    uint256 public immutable coverWindow;
    /// If the reviewer has not resolved a case after this time, reporters can take their bonds back.
    uint256 public immutable resolveTimeout;

    address public reviewer;
    address public pendingReviewer;
    /// The SellarSafe allowed to record payments. Set once.
    address public safe;
    address private immutable deployer;

    /// MUSD owed back to reporters. Never deposited in the Stability Pool.
    uint256 public bondsHeld;
    /// BTC set aside for reporters of confirmed cases.
    uint256 public btcReserved;

    mapping(address suspect => Case) public cases;
    mapping(address suspect => mapping(uint32 round => mapping(address reporter => bool))) public hasReported;
    Receipt[] public receipts;

    event Reported(address indexed suspect, address indexed reporter, uint32 round, bytes32 evidence);
    event Confirmed(address indexed suspect, uint32 reporters, uint256 btcPerReporter);
    event Dismissed(address indexed suspect, uint256 slashed);
    event BondReturned(address indexed suspect, address indexed reporter, uint256 musdAmount, uint256 btcReward);
    event PaymentRecorded(uint256 indexed receiptId, address indexed payer, address indexed payee, uint256 amount);
    event Claimed(uint256 indexed receiptId, address indexed payer, uint256 payout);
    event Rebalanced(uint256 liquid, uint256 inStabilityPool);
    event ReviewerChanged(address indexed reviewer);

    error NotReviewer();
    error NotDeployer();
    error NotSafe();
    error SafeAlreadySet();
    error ZeroAddress();
    error SelfReport();
    error CaseClosed();
    error AlreadyReported();
    error NotFlagged();
    error NotConfirmed();
    error NothingToWithdraw();
    error TooEarly();
    error NotPayer();
    error AlreadyClaimed();
    error PaidAfterReport();
    error OutsideCoverWindow();
    error FundBusy();
    error BtcTransferFailed();

    modifier onlyReviewer() {
        if (msg.sender != reviewer) revert NotReviewer();
        _;
    }

    constructor(
        IERC20 musd_,
        IStabilityPool stabilityPool_,
        address reviewer_,
        uint256 bond_,
        uint256 claimCap_,
        uint256 coverWindow_,
        uint256 resolveTimeout_
    ) {
        if (address(musd_) == address(0) || address(stabilityPool_) == address(0) || reviewer_ == address(0)) {
            revert ZeroAddress();
        }
        musd = musd_;
        stabilityPool = stabilityPool_;
        reviewer = reviewer_;
        bond = bond_;
        claimCap = claimCap_;
        coverWindow = coverWindow_;
        resolveTimeout = resolveTimeout_;
        deployer = msg.sender;
    }

    /// BTC gains arrive here from the Stability Pool.
    receive() external payable {}

    // ---------------------------------------------------------------- setup

    function setSafe(address safe_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (safe != address(0)) revert SafeAlreadySet();
        if (safe_ == address(0)) revert ZeroAddress();
        safe = safe_;
    }

    function proposeReviewer(address next) external onlyReviewer {
        pendingReviewer = next;
    }

    function acceptReviewer() external {
        if (msg.sender != pendingReviewer) revert NotReviewer();
        reviewer = msg.sender;
        pendingReviewer = address(0);
        emit ReviewerChanged(msg.sender);
    }

    // ---------------------------------------------------------------- scam list

    /// @notice Report an address as a scam. Locks `bond` MUSD from the caller.
    /// @param evidence Hash of the evidence kept off-chain (for example the email that carried the address).
    function report(address suspect, bytes32 evidence) external nonReentrant {
        if (suspect == address(0)) revert ZeroAddress();
        if (suspect == msg.sender) revert SelfReport();
        Case storage c = cases[suspect];
        if (c.status == Status.Confirmed) revert CaseClosed();
        if (c.status != Status.Flagged) {
            c.status = Status.Flagged;
            c.firstReportAt = uint64(block.timestamp);
            c.resolvedAt = 0;
        }
        if (hasReported[suspect][c.round][msg.sender]) revert AlreadyReported();
        hasReported[suspect][c.round][msg.sender] = true;
        c.reporters += 1;
        bondsHeld += bond;
        musd.safeTransferFrom(msg.sender, address(this), bond);
        emit Reported(suspect, msg.sender, c.round, evidence);
    }

    /// @notice Reviewer confirms the case. Reporters can take their bonds back plus a share of BTC gains.
    function confirm(address suspect) external onlyReviewer {
        Case storage c = cases[suspect];
        if (c.status != Status.Flagged) revert NotFlagged();
        c.status = Status.Confirmed;
        c.resolvedAt = uint64(block.timestamp);
        uint256 freeBtc = address(this).balance - btcReserved;
        uint256 perReporter = (freeBtc * REWARD_BPS) / BPS / c.reporters;
        c.btcPerReporter = perReporter;
        btcReserved += perReporter * c.reporters;
        emit Confirmed(suspect, c.reporters, perReporter);
    }

    /// @notice Reviewer dismisses the case as false. The bonds move into the cover fund.
    function dismiss(address suspect) external onlyReviewer {
        Case storage c = cases[suspect];
        if (c.status != Status.Flagged) revert NotFlagged();
        uint256 slashed = bond * c.reporters;
        bondsHeld -= slashed;
        c.status = Status.Dismissed;
        c.resolvedAt = uint64(block.timestamp);
        c.round += 1;
        c.reporters = 0;
        emit Dismissed(suspect, slashed);
    }

    /// @notice Take back a bond: after the case is confirmed (with the BTC reward), or after the
    /// reviewer has left the case unresolved for `resolveTimeout`.
    function withdrawBond(address suspect) external nonReentrant {
        Case storage c = cases[suspect];
        uint32 round = c.round;
        if (!hasReported[suspect][round][msg.sender]) revert NothingToWithdraw();
        uint256 btcReward;
        if (c.status == Status.Confirmed) {
            btcReward = c.btcPerReporter;
            btcReserved -= btcReward;
        } else if (c.status == Status.Flagged) {
            if (block.timestamp < uint256(c.firstReportAt) + resolveTimeout) revert TooEarly();
            c.reporters -= 1;
            if (c.reporters == 0) {
                c.status = Status.None;
                c.round = round + 1;
            }
        } else {
            revert NothingToWithdraw();
        }
        hasReported[suspect][round][msg.sender] = false;
        bondsHeld -= bond;
        musd.safeTransfer(msg.sender, bond);
        if (btcReward > 0) {
            (bool ok,) = msg.sender.call{value: btcReward}("");
            if (!ok) revert BtcTransferFailed();
        }
        emit BondReturned(suspect, msg.sender, bond, btcReward);
    }

    function statusOf(address who) external view returns (Status) {
        return cases[who].status;
    }

    /// @return status, number of active reporters, MUSD bonded behind the flag
    function flagInfo(address who) external view returns (Status, uint32, uint256) {
        Case storage c = cases[who];
        return (c.status, c.reporters, bond * c.reporters);
    }

    // ---------------------------------------------------------------- cover fund

    /// @notice Called by SellarSafe after it has sent the cover fee for a payment.
    function recordPayment(address payer, address payee, uint256 amount) external returns (uint256 receiptId) {
        if (msg.sender != safe) revert NotSafe();
        receiptId = receipts.length;
        receipts.push(
            Receipt({payer: payer, payee: payee, amount: uint128(amount), paidAt: uint64(block.timestamp), claimed: false})
        );
        emit PaymentRecorded(receiptId, payer, payee, amount);
    }

    /// @notice Refund for a payment whose payee was later confirmed as a scam.
    /// Covered only if the payment was made before the first report, and the case was confirmed
    /// within `coverWindow` of the payment.
    function claim(uint256 receiptId) external nonReentrant {
        Receipt storage r = receipts[receiptId];
        if (r.payer != msg.sender) revert NotPayer();
        if (r.claimed) revert AlreadyClaimed();
        Case storage c = cases[r.payee];
        if (c.status != Status.Confirmed) revert NotConfirmed();
        if (r.paidAt >= c.firstReportAt) revert PaidAfterReport();
        if (uint256(c.resolvedAt) > uint256(r.paidAt) + coverWindow) revert OutsideCoverWindow();

        uint256 payout = r.amount;
        if (payout > claimCap) payout = claimCap;
        uint256 shareCap = (fundAssets() * MAX_CLAIM_SHARE_BPS) / BPS;
        if (payout > shareCap) payout = shareCap;

        _ensureLiquid(payout);
        r.claimed = true;
        musd.safeTransfer(msg.sender, payout);
        emit Claimed(receiptId, msg.sender, payout);
    }

    /// @notice MUSD in the cover fund that is in this contract (excludes reporter bonds).
    function fundLiquid() public view returns (uint256) {
        return musd.balanceOf(address(this)) - bondsHeld;
    }

    /// @notice Total MUSD in the cover fund: liquid plus the Stability Pool deposit after any losses.
    function fundAssets() public view returns (uint256) {
        return fundLiquid() + stabilityPool.getCompoundedMUSDDeposit(address(this));
    }

    /// @notice BTC earned in the Stability Pool: held here and still pending in the pool.
    function fundBtc() external view returns (uint256 held, uint256 pending) {
        return (address(this).balance - btcReserved, stabilityPool.getDepositorCollateralGain(address(this)));
    }

    /// @notice Move the fund toward its target split: BUFFER_BPS liquid, the rest in the Stability Pool.
    /// Anyone can call. If the pool refuses a withdrawal, the call still succeeds and can be repeated.
    function rebalance() external nonReentrant {
        uint256 liquid = fundLiquid();
        uint256 target = (fundAssets() * BUFFER_BPS) / BPS;
        if (liquid > target) {
            uint256 excess = liquid - target;
            musd.forceApprove(address(stabilityPool), excess);
            stabilityPool.provideToSP(excess);
        } else if (liquid < target) {
            _tryWithdraw(target - liquid);
        }
        emit Rebalanced(fundLiquid(), stabilityPool.getCompoundedMUSDDeposit(address(this)));
    }

    function receiptCount() external view returns (uint256) {
        return receipts.length;
    }

    function _ensureLiquid(uint256 amount) internal {
        uint256 liquid = fundLiquid();
        if (liquid < amount) {
            _tryWithdraw(amount - liquid);
            if (fundLiquid() < amount) revert FundBusy();
        }
    }

    /// The pool reverts while any trove is under-collateralised, or when there is no deposit.
    function _tryWithdraw(uint256 amount) internal {
        if (stabilityPool.getCompoundedMUSDDeposit(address(this)) == 0) return;
        try stabilityPool.withdrawFromSP(amount) {} catch {}
    }
}
