// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/interfaces/IYieldAdapter.sol";
import "../../src/interfaces/ISwapAdapter.sol";

// Verifies interfaces compile correctly. Replace with real contract tests as they are implemented.
contract InterfacesTest is Test {
    function test_interfaces_compile() public pure {
        // IYieldAdapter and ISwapAdapter imported above - if this compiles, interfaces are valid.
        assertTrue(true);
    }
}
