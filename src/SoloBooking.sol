// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./ITribalToken.sol";

contract SoloBooking is Ownable2Step {
    error InvalidDateRange(uint256 startDate, uint256 endDate);
    error DatesNotAvailable(uint256 homeId, uint256 date);
    error HomeAlreadyRegistered();
    error NotHomeOwner();
    error TokenTransferFailed(address token, uint256 amount);
    error HomeNotListed();
    error InvalidHomeData();
    error InvalidPaymentMethod(ITribalToken.PaymentType paymentType);
    error InvalidPrice(string tokenType);

    uint256 private constant FUTURE_DATES = 100;
    uint256 private constant SECONDS_PER_DAY = 86400;

    // Enum for home status on a specific date
    enum HomeStatus { Available, Booked }

    struct HomeListing {
        bytes32 contentHash;    
        uint256 tribalPrice;      
        uint256 usdcPrice;    
        bool isActive;         
        bool acceptsTribal;      
        bool acceptsUsdc;
        bool isFree;
        uint8[FUTURE_DATES] dailyStatus;
    }

        // For updating existing listings
    struct UpdateListingParams {
        bytes32 contentHash;
        uint256 tribalPrice;
        uint256 usdcPrice;
        bool acceptsTribal;
        bool acceptsUsdc;
        bool isFree;
        bool updateContent;     // flags to indicate which fields
        bool updateTribalPrice; // should be updated
        bool updateUsdcPrice;
        bool updateAcceptsTribal;
        bool updateAcceptsUsdc;
        bool updateIsFree;
    }

    // Single mapping for all home data
    mapping(uint256 homeId => HomeListing) public homes;
    mapping(uint256 homeId => address owner) public homeOwners;
    mapping(address owner => uint256[] homeIds) public ownerHomes;

    event BookingConfirmed(uint256 indexed homeId, uint256 requestId);
    event TribalTokenAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event HomeOwnershipRegistered(uint256 indexed homeId, address indexed owner);
    event AvailabilityUpdatedBatch(
        uint256 indexed homeId, 
        uint256 startDate, 
        uint256 endDate, 
        HomeStatus status
    );
    event HomeListed(
        uint256 indexed homeId,
        bytes32 indexed contentHash,
        uint256 timestamp
    );
    event UsdcAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event PaymentProcessed(
        uint256 indexed homeId, 
        uint256 indexed requestId, 
        address indexed paymentToken,
        uint256 amount
    );
    event ListingStatusUpdated(uint256 indexed homeId, bool isActive);

    // Add this state variable near the top with other contract state variables
    address public tribalTokenAddress;
    address public usdcAddress;

    // Add state variable to track next homeId
    uint256 private nextHomeId;

    // Add new struct for booking details
    struct Booking {
        uint256 homeId;
        uint256 startDay;
        uint256 endDay;
        uint256 totalAmount;
        address paymentToken;
        bool active;  // for potential cancellations in the future
    }

    // Add new mappings
    mapping(address user => Booking[] bookings) public userBookings;
    mapping(uint256 bookingId => address owner) public bookingOwner;
    uint256 private nextBookingId;

    // Add new mapping to track owner's bookings
    mapping(address owner => Booking[] bookings) public ownerBookings;

    // Add constructor to set TribalToken address
    constructor(address _tribalTokenAddress, address _usdcAddress) Ownable(msg.sender) {
        tribalTokenAddress = _tribalTokenAddress;
        usdcAddress = _usdcAddress;
        emit TribalTokenAddressUpdated(address(0), _tribalTokenAddress);
    }

    // Add modifiers for common checks
    modifier onlyHomeOwner(uint256 homeId) {
        if (msg.sender != homeOwners[homeId]) {
            revert NotHomeOwner();
        }
        _;
    }

    modifier validDateRange(uint256 startDate, uint256 endDate) {
        if (startDate > endDate) {
            revert InvalidDateRange(startDate, endDate);
        }
        _;
    }

    modifier datesAvailable(uint256 homeId, uint256 startDate, uint256 endDate) {
        uint256 date = startDate;
        do {
            if (uint8(homes[homeId].dailyStatus[date]) != uint8(HomeStatus.Available)) {
                revert DatesNotAvailable(homeId, date);
            }
        } while (++date <= endDate);  // More gas efficient than for loop
        _;
    }

    function book(
        uint256 homeId,
        uint256 startTimestamp,
        uint256 endTimestamp,
        ITribalToken.PaymentType paymentType
    ) external {
        uint256 startDay = startTimestamp / SECONDS_PER_DAY;
        uint256 endDay = endTimestamp / SECONDS_PER_DAY;
        
        uint256 currentDay = _getCurrentDay();
        
        // Check if dates are valid
        if (startDay < currentDay || endDay >= currentDay + FUTURE_DATES) {
            revert InvalidDateRange(startDay, endDay);
        }

        // Convert to array indices
        uint256 startIndex = startDay - currentDay;
        uint256 endIndex = endDay - currentDay;
        
        _processBooking(homeId, startIndex, endIndex, paymentType);
    }

    // Internal function to handle booking logic
    function _processBooking(
        uint256 homeId,
        uint256 startDate,
        uint256 endDate,
        ITribalToken.PaymentType paymentType
    ) internal {
        HomeListing storage listing = homes[homeId];
        address owner = homeOwners[homeId];
        
        if ((paymentType == ITribalToken.PaymentType.Tribal && !listing.acceptsTribal) || 
            (paymentType == ITribalToken.PaymentType.USDC && !listing.acceptsUsdc)) {
            revert InvalidPaymentMethod(paymentType);
        }
        
        uint256 totalAmount = _calculateTotalAmount(startDate, endDate, paymentType, listing);
        address tokenAddress = paymentType == ITribalToken.PaymentType.Tribal ? tribalTokenAddress : usdcAddress;
        
        if (paymentType == ITribalToken.PaymentType.USDC) {
            if (!IERC20(usdcAddress).transferFrom(
                msg.sender,
                owner,
                totalAmount
            )) {
                revert TokenTransferFailed(usdcAddress, totalAmount);
            }
        } else {
            if (!ITribalToken(tribalTokenAddress).transferTokens(
                msg.sender,
                owner,
                totalAmount,
                paymentType
            )) {
                revert TokenTransferFailed(tribalTokenAddress, totalAmount);
            }
        }
        
        _updateAvailability(homeId, startDate, endDate);
        emit PaymentProcessed(homeId, block.timestamp, tokenAddress, totalAmount);
        emit AvailabilityUpdatedBatch(homeId, startDate, endDate, HomeStatus.Booked);
        emit BookingConfirmed(homeId, block.timestamp);

        // Store booking details
        Booking memory newBooking = Booking({
            homeId: homeId,
            startDay: startDate + _getCurrentDay(),
            endDay: endDate + _getCurrentDay(),
            totalAmount: totalAmount,
            paymentToken: tokenAddress,
            active: true
        });
        
        uint256 bookingId = nextBookingId++;
        userBookings[msg.sender].push(newBooking);
        ownerBookings[owner].push(newBooking);
        bookingOwner[bookingId] = msg.sender;
    }

    // Function to register home ownership
    function registerHome(
        bytes32 contentHash,
        uint256 tribalPrice,
        uint256 usdcPrice,
        bool acceptsTribal,
        bool acceptsUsdc,
        bool isFree
    ) external returns (uint256) {
        _validateHomeData(contentHash, tribalPrice, usdcPrice, acceptsTribal, acceptsUsdc, isFree);
        
        uint256 homeId = nextHomeId;
        
        homeOwners[homeId] = msg.sender;
        ownerHomes[msg.sender].push(homeId);
        
        unchecked {
            nextHomeId++;
        }
        
        // Initialize dailyStatus array
        uint8[FUTURE_DATES] memory initialStatus;
        unchecked {
            for (uint256 i = 0; i < FUTURE_DATES; ++i) {
                initialStatus[i] = uint8(HomeStatus.Available);
            }
        }
        
        homes[homeId] = HomeListing({
            contentHash: contentHash,
            tribalPrice: tribalPrice,
            usdcPrice: usdcPrice,
            acceptsTribal: acceptsTribal,
            acceptsUsdc: acceptsUsdc,
            isFree: isFree,
            isActive: true,
            dailyStatus: initialStatus
        });
        
        emit HomeListed(homeId, contentHash, block.timestamp);
        return homeId;
    }

    function updateListing(
        uint256 homeId,
        UpdateListingParams calldata params
    ) external onlyHomeOwner(homeId) {
        HomeListing storage listing = homes[homeId];
        
        // Update only the fields that are specified
        if (params.updateContent) {
            if (params.contentHash == bytes32(0)) revert InvalidHomeData();
            listing.contentHash = params.contentHash;
        }
        
        if (params.updateTribalPrice) {
            if (params.acceptsTribal && params.tribalPrice == 0) revert InvalidPrice("TRIBAL");
            listing.tribalPrice = params.tribalPrice;
        }
        
        if (params.updateUsdcPrice) {
            if (params.acceptsUsdc && params.usdcPrice == 0) revert InvalidPrice("USDC");
            listing.usdcPrice = params.usdcPrice;
        }
        
        if (params.updateAcceptsTribal) {
            listing.acceptsTribal = params.acceptsTribal;
        }
        
        if (params.updateAcceptsUsdc) {
            listing.acceptsUsdc = params.acceptsUsdc;
        }
        
        if (params.updateIsFree) {
            listing.isFree = params.isFree;
        }
        
        // Validate the final state
        _validateHomeData(
            listing.contentHash,
            listing.tribalPrice,
            listing.usdcPrice,
            listing.acceptsTribal,
            listing.acceptsUsdc,
            listing.isFree
        );
        
        emit HomeListed(homeId, listing.contentHash, block.timestamp);
    }

    // Separate validation function for cleaner code and reusability
    function _validateHomeData(
        bytes32 contentHash,
        uint256 tribalPrice,
        uint256 usdcPrice,
        bool acceptsTribal,
        bool acceptsUsdc,
        bool isFree
    ) internal pure {
        if (contentHash == bytes32(0)) revert InvalidHomeData();
        
        // If it's free, no need to check payment methods
        if (isFree) {
            return;
        }
        
        // Otherwise, must accept at least one payment type
        if (!acceptsTribal && !acceptsUsdc) revert InvalidHomeData();
        
        // Only validate prices if accepting that token and not free
        if (acceptsTribal && tribalPrice == 0) revert InvalidPrice("TRIBAL");
        if (acceptsUsdc && usdcPrice == 0) revert InvalidPrice("USDC");
    }

    // If you add the Tribal token update function, include event
    function updateTribalTokenAddress(
        address newAddress
    ) external payable onlyOwner {
        address oldAddress = tribalTokenAddress;
        tribalTokenAddress = newAddress;
        emit TribalTokenAddressUpdated(oldAddress, newAddress);
    }

    function updateUsdcAddress(address newAddress) external onlyOwner {
        address oldAddress = usdcAddress;
        usdcAddress = newAddress;
        emit UsdcAddressUpdated(oldAddress, newAddress);
    }

    function _calculateTotalAmount(
        uint256 startDate,
        uint256 endDate,
        ITribalToken.PaymentType paymentType,
        HomeListing memory listing
    ) internal pure returns (uint256) {
        return (paymentType == ITribalToken.PaymentType.Tribal ? listing.tribalPrice : listing.usdcPrice) * 
               (endDate - startDate + 1);
    }

    function _updateAvailability(
        uint256 homeId,
        uint256 startDate,
        uint256 endDate
    ) internal {
        unchecked {
            uint256 date = startDate;
            do {
                homes[homeId].dailyStatus[date] = uint8(HomeStatus.Booked);
            } while (++date <= endDate);
        }
    }

    function getOwnerHomes(address owner) external view returns (uint256[] memory) {
        return ownerHomes[owner];
    }

    function toggleListingStatus(uint256 homeId) external onlyHomeOwner(homeId) {
        homes[homeId].isActive = !homes[homeId].isActive;
        emit ListingStatusUpdated(homeId, homes[homeId].isActive);
    }

    function getHomeAvailability(uint256 homeId) external view returns (uint8[FUTURE_DATES] memory) {
        return homes[homeId].dailyStatus;
    }

    // Helper function to get current day number
    function _getCurrentDay() internal view returns (uint256) {
        return block.timestamp / SECONDS_PER_DAY;
    }

    // Add function to get user's bookings
    function getUserBookings(address user) external view returns (Booking[] memory) {
        return userBookings[user];
    }

    // Add function to get owner's bookings
    function getOwnerBookings(address owner) external view returns (Booking[] memory) {
        return ownerBookings[owner];
    }
}