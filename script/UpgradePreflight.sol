// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Checks run before an upgrade broadcasts, so a contract is never upgraded ahead of a
///         dependency it now calls. Upgrade order: PaymentTokenRegistry, ReserveManager, then
///         Marketplace / PrimarySaleAuction / SwapEscrow / RedemptionManager, then DGENFT.
library UpgradePreflight {
    /// @dev ReserveManager, Marketplace, PrimarySaleAuction, SwapEscrow and RedemptionManager call
    ///      `PaymentTokenRegistry.requireSequencerUp()`. Against an older registry those calls
    ///      revert, which would block settlement, purchases and redemption requests.
    function requireSequencerAwareRegistry(address paymentRegistry) internal view {
        (bool ok,) = paymentRegistry.staticcall(abi.encodeWithSignature("requireSequencerUp()"));
        require(ok, "Upgrade PaymentTokenRegistry first (no requireSequencerUp), or wait out a sequencer outage");
    }

    /// @dev DGENFT calls `ReserveManager.hasReserveAssets(gemId)` on every transfer. Against an
    ///      older ReserveManager that call reverts, which would block every transfer.
    function requireReserveAssetsView(address reserveManager) internal view {
        (bool ok, bytes memory result) =
            reserveManager.staticcall(abi.encodeWithSignature("hasReserveAssets(uint256)", uint256(0)));
        require(ok && result.length == 32, "Upgrade ReserveManager first (no hasReserveAssets)");
    }
}
