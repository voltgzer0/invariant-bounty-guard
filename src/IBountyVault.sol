// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBountyVault
/// @notice Third-party-sponsored bounty escrow for `InvariantGuard`-protected
/// targets. Decouples the bounty pool from the protected contract so audit
/// firms, ecosystem programmes, or insurance pools can underwrite a bounty
/// on a target they do not control.
///
/// Roles:
///   * `sponsor` — funds the escrow, authorizes/revokes targets, sets the
///     payout amount per breach.
///   * `target`  — an `InvariantGuard`-style contract that, on a real breach,
///     calls `notifyBreach(reporter)` (typically from a `_onBreach` override).
///     Targets must be explicitly authorized; arbitrary callers cannot drain
///     the escrow.
///   * `reporter` — the external caller whose tx triggered the breach.
///     Earns `bountyAmount` to a pull-pattern credit; withdraws via `claim`.
///
/// Implementation is delivered under license. See README for terms.
interface IBountyVault {
    /// @notice Emitted when a hook target credits a reporter for a real breach.
    event BreachCredited(address indexed target, address indexed reporter, uint256 amount);

    /// @notice Authorized target reports that `reporter` triggered a real breach.
    /// @dev MUST credit `bountyAmount` to the reporter only when the escrow can
    /// cover the new credit plus all outstanding pending credits.
    function notifyBreach(address reporter) external;

    /// @notice Pull-pattern claim. Caller withdraws their accrued credit.
    function claim() external;

    /// @notice View the pending bounty owed to `reporter`.
    function pendingBounty(address reporter) external view returns (uint256);

    /// @notice The fixed amount credited per accepted breach notification.
    function bountyAmount() external view returns (uint256);

    /// @notice Sum of all outstanding credits — used to refuse over-commit.
    function totalPending() external view returns (uint256);

    /// @notice True iff `target` is authorized to call `notifyBreach`.
    function authorized(address target) external view returns (bool);

    /// @notice The address that funded the escrow and controls authorization.
    function sponsor() external view returns (address);
}
