//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITribalToken.sol";
import "./ISoloBooking.sol";

contract SharedBooking is Ownable2Step {
    error BookingNotActive();
    error NoSharesAvailable();
    error AlreadyParticipating();
    error TokenTransferFailed(address token, uint256 amount);
    error InvalidDateRange();
    error DatesNotAvailable();
    error InvalidShareCount();
    error HomeNotListed();
    error InvalidPaymentMethod(ITribalToken.PaymentType paymentType);

    struct SharedBookingData {
        uint256 totalAmount;
        uint256 remainingAmount;
        uint256 numSharesAvailable;
        uint256 pricePerShare;
        uint256 startDate;
        uint256 endDate;
        bool isActive;
        mapping(address participant => uint256 numShares) shares;
        address[] participants;
    }

    // State variables
    ISoloBooking public immutable soloBookingContract;
    mapping(uint256 homeId => mapping(uint256 requestId => SharedBookingData)) public sharedBookings;  // homeId => requestId => SharedBookingData

    // Events
    event SharedBookingInitiated(
        uint256 indexed homeId, 
        uint256 indexed requestId, 
        uint256 totalShares, 
        uint256 pricePerShare
    );
    event SharePurchased(
        uint256 indexed homeId, 
        uint256 indexed requestId, 
        address indexed buyer, 
        uint256 shareAmount
    );
    event SharedBookingFinalized(
        uint256 indexed homeId, 
        uint256 indexed requestId, 
        address[] participants
    );

    constructor(address _soloBookingContract) Ownable(msg.sender) {
        soloBookingContract = ISoloBooking(_soloBookingContract);
    }

    function initiateSharedBooking(
        uint256 homeId,
        uint256 startDate,
        uint256 endDate,
        uint256 totalShares,
        ITribalToken.PaymentType paymentType
    ) external returns (uint256) {
        ISoloBooking.HomeListing memory listing = soloBookingContract.homeListings(homeId);

        if ((paymentType == ITribalToken.PaymentType.Tribal && !listing.acceptsTribal) || 
        (paymentType == ITribalToken.PaymentType.USDC && !listing.acceptsUsdc)) {
        revert InvalidPaymentMethod(paymentType);
    }
        if (startDate >= endDate || startDate <= block.timestamp) revert InvalidDateRange();
        if (totalShares < 2) revert InvalidShareCount();
        
        // Add check for date availability
        uint256 date = startDate;
        do {
            if (uint8(soloBookingContract.homeAvailability(homeId).dailyStatus[date]) != uint8(ISoloBooking.HomeStatus.Available)) {
                revert DatesNotAvailable();
            }
        } while (++date <= endDate);
        
        // Calculate total cost through SoloBooking contract
        if (!listing.isActive) revert HomeNotListed();
        uint256 totalAmount = soloBookingContract._calculateTotalAmount(
            startDate, 
            endDate, 
            paymentType,
            listing
        );
        
        uint256 pricePerShare = totalAmount / totalShares;
        uint256 requestId = uint256(keccak256(abi.encodePacked(homeId, block.timestamp, msg.sender)));
        
        SharedBookingData storage booking = sharedBookings[homeId][requestId];
        booking.totalAmount = totalAmount;
        booking.remainingAmount = totalAmount;
        booking.numSharesAvailable = totalShares;
        booking.pricePerShare = pricePerShare;
        booking.startDate = startDate;
        booking.endDate = endDate;
        booking.isActive = true;
        
        // First participant buys their share
        _buyShare(homeId, requestId, paymentType);
        
        emit SharedBookingInitiated(homeId, requestId, totalShares, pricePerShare);
        return requestId;
    }

    function buyShare(
        uint256 homeId,
        uint256 requestId,
        ITribalToken.PaymentType paymentType
    ) external {
        _buyShare(homeId, requestId, paymentType);
    }

    function _buyShare(
        uint256 homeId,
        uint256 requestId,
        ITribalToken.PaymentType paymentType
    ) internal {
        SharedBookingData storage booking = sharedBookings[homeId][requestId];
        
        if (!booking.isActive) revert BookingNotActive();
        if (booking.numSharesAvailable == 0) revert NoSharesAvailable();
        if (booking.shares[msg.sender] != 0) revert AlreadyParticipating();

        address tokenAddress = paymentType == ITribalToken.PaymentType.Tribal ? 
            soloBookingContract.tribalTokenAddress() : 
            soloBookingContract.usdcAddress();
            
        address homeOwner = soloBookingContract.homeOwners(homeId);

        // Transfer payment to home owner
        bool success = IERC20(tokenAddress).transferFrom(
            msg.sender,
            homeOwner,
            booking.pricePerShare
        );
        
        if (!success) {
            revert TokenTransferFailed(tokenAddress, booking.pricePerShare);
        }

        booking.shares[msg.sender] = 1;
        booking.participants.push(msg.sender);
        booking.numSharesAvailable--;
        booking.remainingAmount -= booking.pricePerShare;

        emit SharePurchased(homeId, requestId, msg.sender, 1);

        if (booking.numSharesAvailable == 0) {
            _finalizeSharedBooking(homeId, requestId);
        }
    }

    function _finalizeSharedBooking(uint256 homeId, uint256 requestId) internal {
        SharedBookingData storage booking = sharedBookings[homeId][requestId];
        booking.isActive = false;
        
        // Update availability through SoloBooking contract
        soloBookingContract._updateAvailability(homeId, booking.startDate, booking.endDate);
        
        emit SharedBookingFinalized(homeId, requestId, booking.participants);
    }

    // View functions
    function getBookingParticipants(uint256 homeId, uint256 requestId) 
        external 
        view 
        returns (address[] memory) 
    {
        return sharedBookings[homeId][requestId].participants;
    }

    function getShareCount(uint256 homeId, uint256 requestId, address participant) 
        external 
        view 
        returns (uint256) 
    {
        return sharedBookings[homeId][requestId].shares[participant];
    }
}