// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "src/TribalToken.sol";

contract DeployTribalToken is Script {
    uint256 public constant MEMBERSHIP_FEE = 0.001 ether;
    address public constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external returns (address) {
        vm.startBroadcast();
        TribalToken tribalToken = new TribalToken(MEMBERSHIP_FEE);
        vm.stopBroadcast();
        return address(tribalToken);
    }
}
