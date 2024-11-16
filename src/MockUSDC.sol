// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        // Mint 1000 USDC to deployer (with 6 decimals)
        _mint(msg.sender, 1000 * 1e6); // 1000 USDC
    }

    // Override decimals to match USDC's 6 decimals (instead of default 18)
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // Optional: Add mint function for testing (remove for production)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}