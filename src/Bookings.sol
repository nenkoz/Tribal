// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./ITribalTypes.sol";

// Add interface for TribalToken's specific functions
interface ITribalToken is IERC20 {
    function transferTokens(address to, uint256 amount, ITribalTypes.PaymentType tokenType) external returns (bool);
}

contract Bookings is Ownable2Step {
    error InvalidDateRange(uint256 startDate, uint256 endDate);
    error DatesNotAvailable(uint256 homeId, uint256 date);
    error HomeAlreadyRegistered();
    error NotHomeOwner();
    error TokenTransferFailed(address token, uint256 amount);
    error HomeNotListed();
    error InvalidHomeData();
    error InvalidPaymentMethod(ITribalTypes.PaymentType paymentType);
    error InvalidPrice(string tokenType);

    uint256 private constant FUTURE_DATES = 100;
    uint256 private constant SECONDS_PER_DAY = 86400;

    // Enum for home status on a specific date
    enum HomeStatus { Available, Unavailable, Booked }

    struct HomeListing {
        bytes32 contentHash;    
        uint256 tribalPrice;      
        uint256 usdcPrice;    
        bool isActive;         
        bool acceptsTribal;      
        bool acceptsUsdc;
        bool isFree;     // Add this field
    }

    struct HomeAvailability {
        uint8[FUTURE_DATES] dailyStatus;  // uint8 instead of enum saves gas
        uint256 startDay;
    }

    // Replace homeStatus mapping with new structure
    mapping(uint256 homeId => HomeAvailability) public homeAvailability;
    
    // Mapping: homeId => owner address
    mapping(uint256 homeId => address owner) public homeOwners;
    
    // Add reverse mapping to track all homes per owner
    mapping(address owner => uint256[] homeIds) public ownerHomes;

    // Mapping remains the same but stores less data
    mapping(uint256 homeId => HomeListing listing) public homeListings;

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

    // Add this state variable near the top with other contract state variables
    address public tribalTokenAddress;
    address public usdcAddress;

    // Add state variable
    uint256[] public allHomes;

    // Add state variable to track next homeId
    uint256 private nextHomeId;

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
            if (uint8(homeAvailability[homeId].dailyStatus[date]) != uint8(HomeStatus.Available)) {
                revert DatesNotAvailable(homeId, date);
            }
        } while (++date <= endDate);  // More gas efficient than for loop
        _;
    }

    function book(
        uint256 homeId,
        uint256 startDate,
        uint256 endDate,
        ITribalTypes.PaymentType paymentType
    ) external validDateRange(startDate, endDate) datesAvailable(homeId, startDate, endDate) {
        _processBooking(homeId, startDate, endDate, paymentType);
    }

    // Internal function to handle booking logic
    function _processBooking(
        uint256 homeId,
        uint256 startDate,
        uint256 endDate,
        ITribalTypes.PaymentType paymentType
    ) internal {
        HomeListing memory listing = homeListings[homeId];
        address owner = homeOwners[homeId];
        
        if ((paymentType == ITribalTypes.PaymentType.Tribal && !listing.acceptsTribal) || 
            (paymentType == ITribalTypes.PaymentType.USDC && !listing.acceptsUsdc)) {
            revert InvalidPaymentMethod(paymentType);
        }
        
        uint256 totalAmount = _calculateTotalAmount(startDate, endDate, paymentType, listing);
        address tokenAddress = paymentType == ITribalTypes.PaymentType.Tribal ? tribalTokenAddress : usdcAddress;
        
        if (!ITribalToken(tokenAddress).transferTokens(owner, totalAmount, paymentType)) {
            revert TokenTransferFailed(tokenAddress, totalAmount);
        }
        
        _updateAvailability(homeId, startDate, endDate);
        emit PaymentProcessed(homeId, block.timestamp, tokenAddress, totalAmount);
        emit AvailabilityUpdatedBatch(homeId, startDate, endDate, HomeStatus.Booked);
        emit BookingConfirmed(homeId, block.timestamp);
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
        
        // Check if sender already owns this home
        if (homeOwners[homeId] != address(0)) {
            // If updating existing home, verify ownership
            if (homeOwners[homeId] != msg.sender) {
                revert NotHomeOwner();
            }
        } else {
            // New home registration
            allHomes.push(homeId);
            homeOwners[homeId] = msg.sender;
            ownerHomes[msg.sender].push(homeId);
            
            // Increment nextHomeId only for new registrations
            unchecked {
                nextHomeId++;
            }
        }
        
        // Initialize or update availability array
        unchecked {
            for (uint256 i = 0; i < FUTURE_DATES; ++i) {
                homeAvailability[homeId].dailyStatus[i] = uint8(HomeStatus.Unavailable);
            }
            homeAvailability[homeId].startDay = block.timestamp / SECONDS_PER_DAY;
        }
        
        // Create or update listing
        homeListings[homeId] = HomeListing({
            contentHash: contentHash,
            tribalPrice: tribalPrice,
            usdcPrice: usdcPrice,
            acceptsTribal: acceptsTribal,
            acceptsUsdc: acceptsUsdc,
            isFree: isFree,
            isActive: true
        });
        
        emit HomeListed(homeId, contentHash, block.timestamp);
        
        return homeId;
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
        ITribalTypes.PaymentType paymentType,
        HomeListing memory listing
    ) internal pure returns (uint256) {
        return (paymentType == ITribalTypes.PaymentType.Tribal ? listing.tribalPrice : listing.usdcPrice) * 
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
                homeAvailability[homeId].dailyStatus[date] = uint8(HomeStatus.Booked);
            } while (++date <= endDate);
        }
    }

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
}