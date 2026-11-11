// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice ERC-20 `transfer` whose token can neither exhaust nor revert the calling frame, for the
///         two output hops that must survive a token refusing them: BatchExecutor to a strategy
///         account, and the strategy account to its owner.
library BoundedTransfer {
    /// @notice The caller left too little gas to give the token its full allowance and still act on
    ///         a refusal. A transaction-level shortfall, never a failed delivery.
    error InsufficientOutputGas(uint256 available, uint256 required);

    /// @notice Attempts `token.transfer(to, amount)` with a fixed gas allowance and reports whether
    ///         it was delivered, instead of reverting when the token refuses.
    /// @dev Neither `try IERC20.transfer() returns (bool)` nor a Solidity low-level call is safe on
    ///      these paths. A `returns (bool)` clause is decoded in the caller's frame, so a token that
    ///      omits the bool (USDT-style), returns the wrong width, or returns a dirty bool reverts
    ///      there. `(bool, bytes memory) = token.call(...)` fixes that but copies the token's
    ///      whole returndata into memory first, so a token that burns its gas and returns a large
    ///      payload leaves the frame out of gas before the fallback is written.
    ///
    ///      So the token gets exactly `transferGas`, the output buffer is empty, and only an exact
    ///      32-byte return is copied. Delivered means the call succeeded and returned either no data
    ///      or exactly the 32-byte word 1; every other outcome is `false`. `token` must be a
    ///      contract: a call to an address without code succeeds with no data and counts as
    ///      delivered.
    ///
    ///      A fixed allowance rather than "everything but a reserve" is deliberate: with the latter,
    ///      too low a transaction gas limit would starve a working token into the fallback and still
    ///      succeed, so `eth_estimateGas` could settle on a limit that turns the last deliveries in a
    ///      batch into fallbacks. Requiring `transferGas * 64 / 63 + reserveGas` up front makes too
    ///      little gas a revert, which the estimate then raises. The 64/63 factor covers the
    ///      EIP-150 rule that a call can forward at most 63/64 of the remaining gas.
    /// @param transferGas Gas forwarded to the token's `transfer`.
    /// @param reserveGas Gas that must remain afterwards for the caller to record a refusal.
    /// @return delivered Whether the token accepted the transfer. Reverts `InsufficientOutputGas`
    ///         instead of returning when less than `transferGas * 64 / 63 + reserveGas` is left.
    function tryTransfer(address token, address to, uint256 amount, uint256 transferGas, uint256 reserveGas)
        internal
        returns (bool delivered)
    {
        uint256 required = transferGas * 64 / 63 + reserveGas;
        uint256 available = gasleft();
        if (available < required) revert InsufficientOutputGas(available, required);

        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
        assembly ("memory-safe") {
            let ok := call(transferGas, token, 0, add(data, 0x20), mload(data), 0, 0)
            switch returndatasize()
            case 0 { delivered := ok }
            case 32 {
                returndatacopy(0, 0, 32)
                delivered := and(ok, eq(mload(0), 1))
            }
        }
    }
}
