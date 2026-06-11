// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IInvariantGuard
/// @author voltgzer0
/// @notice Public interface of the Invariant Bounty Guard primitive.
///
/// The implementation wraps protected operations in a two-frame revert/catch:
/// the inner frame runs the body and asserts the invariant, the outer catches
/// the breach revert, rolls back the body's state changes EVM-atomically, and
/// pays the original caller a bounty from an internal escrow.
///
/// This file is published as a stable surface for integrators and auditors.
/// The implementation, monetization layer, and integration support are
/// commercial — see README for licensing.
interface IInvariantGuard {
    // --------------------------------------------------------------------- //
    //                                  Events                               //
    // --------------------------------------------------------------------- //

    /// @notice Emitted when a real breach has been caught and processed.
    /// @param reporter  The original external caller whose transaction tripped the guard.
    /// @param preMag    Invariant magnitude captured before the body ran.
    /// @param postMag   Invariant magnitude observed at the moment of breach (decoded from inner revert data).
    event InvariantBreached(address indexed reporter, uint256 preMag, uint256 postMag);

    /// @notice Emitted when funds are added to the bounty escrow.
    event BountyFunded(address indexed funder, uint256 amount);

    /// @notice Emitted when a credited bounty is pulled by its recipient.
    event BountyClaimed(address indexed reporter, uint256 amount);

    /// @notice Emitted when the conditional pause has been tripped by a real breach.
    event PauseTripped(address indexed reporter);

    // --------------------------------------------------------------------- //
    //                                  Errors                               //
    // --------------------------------------------------------------------- //

    /// @notice Raised in the inner frame when the invariant is broken.
    /// @dev The post-op magnitude is carried in revert data so the outer frame can
    /// compute the delta after the inner has rolled back.
    error InvariantBreach(uint256 postMag);

    /// @notice Sentinel functions of the guard reject any caller other than self.
    error OnlySelf();

    /// @notice Further guarded operations are rejected after a real breach until governance intervenes.
    error AlreadyPaused();

    /// @notice The caller has no accrued bounty to pull.
    error NoBounty();

    /// @notice The outbound bounty payout reverted at the recipient (e.g. reentrancy guard tripped).
    error TransferFailed();

    // --------------------------------------------------------------------- //
    //                                  Views                                //
    // --------------------------------------------------------------------- //

    /// @notice Fixed bounty amount paid per real breach.
    function bountyAmount() external view returns (uint256);

    /// @notice Tracked escrow balance.
    function totalEscrow() external view returns (uint256);

    /// @notice True after a real breach has tripped the pause.
    function paused() external view returns (bool);

    /// @notice Accrued bounty for `reporter`, pullable via `claimBounty`.
    function pendingBounty(address reporter) external view returns (uint256);

    // --------------------------------------------------------------------- //
    //                              State-changing                           //
    // --------------------------------------------------------------------- //

    /// @notice Add ETH to the bounty escrow.
    function fund() external payable;

    /// @notice Withdraw accrued bounty. CEI-ordered, reentrancy-guarded.
    function claimBounty() external;

    /// @notice External assertion endpoint. Inner-only.
    /// @dev Reverts with `InvariantBreach(postMag)` when the protocol invariant is
    /// broken at call time. The revert propagates through the inner frame and rolls
    /// back any body-level state changes before the outer frame catches it.
    function __assertInvariant() external view;
}
