// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ITribalToken {
    enum PaymentType { Tribal, USDC }
    
    function transferTokens(
        address from,
        address to,
        uint256 amount,
        PaymentType tokenType
    ) external returns (bool);
}