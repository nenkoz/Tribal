// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ITribalTypes.sol";

interface ISoloBooking {
    struct HomeListing {
        bytes32 contentHash;    
        uint256 tribalPrice;      
        uint256 usdcPrice;    
        bool isActive;         
        bool acceptsTribal;      
        bool acceptsUsdc;
        bool isFree;
    }

    function homeListings(uint256 homeId) external view returns (HomeListing memory);
    function tribalTokenAddress() external view returns (address);
    function usdcAddress() external view returns (address);
    function homeOwners(uint256 homeId) external view returns (address);
    function _calculateTotalAmount(
        uint256 startDate,
        uint256 endDate,
        ITribalTypes.PaymentType paymentType,
        HomeListing memory listing
    ) external pure returns (uint256);
    function _updateAvailability(
        uint256 homeId,
        uint256 startDate,
        uint256 endDate
    ) external;
}
