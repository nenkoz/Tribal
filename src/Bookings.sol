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
    event HomeUnlisted(uint256 indexed homeId);
    event ListingUpdated(
        uint256 indexed homeId, 
        bytes32 indexed newContentHash,
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

    // Update internal payment function
    function _processPayment(
        address to,
        address tokenAddress,
        uint256 amount,
        ITribalTypes.PaymentType paymentType
    ) internal returns (bool) {
        return ITribalToken(tokenAddress).transferTokens(to, amount, paymentType);
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
        
        if (!_processPayment(owner, tokenAddress, totalAmount, paymentType)) {
            revert TokenTransferFailed(tokenAddress, totalAmount);
        }
        
        _updateAvailability(homeId, startDate, endDate);
        
        emit PaymentProcessed(homeId, block.timestamp, tokenAddress, totalAmount);
        emit AvailabilityUpdatedBatch(homeId, startDate, endDate, HomeStatus.Booked);
        emit BookingConfirmed(homeId, block.timestamp);
    }

    // Function to register home ownership
    function registerHome(
        uint256 homeId,
        bytes32 contentHash,
        uint256 tribalPrice,
        uint256 usdcPrice,
        bool acceptsTribal,
        bool acceptsUsdc
    ) external {
        if (homeOwners[homeId] != address(0)) revert HomeAlreadyRegistered();
        if (contentHash == bytes32(0) || (!acceptsTribal && !acceptsUsdc) || 
            (acceptsTribal && tribalPrice == 0) || (acceptsUsdc && usdcPrice == 0)) {
            revert InvalidHomeData();
        }
        
        // Add to allHomes array
        allHomes.push(homeId);
        
        // Batch storage updates
        homeOwners[homeId] = msg.sender;
        ownerHomes[msg.sender].push(homeId);
        
        // Initialize availability array (unchecked for gas optimization)
        unchecked {
            HomeAvailability storage availability = homeAvailability[homeId];
            uint256 today = block.timestamp / SECONDS_PER_DAY;
            
            for (uint256 i = 0; i < FUTURE_DATES; ++i) {
                availability.dailyStatus[i] = uint8(HomeStatus.Unavailable);
            }
            availability.startDay = today;
        }
        
        // Create listing
        homeListings[homeId] = HomeListing({
            contentHash: contentHash,
            isActive: true,
            tribalPrice: tribalPrice,
            usdcPrice: usdcPrice,
            acceptsTribal: acceptsTribal,
            acceptsUsdc: acceptsUsdc
        });
        
        emit HomeOwnershipRegistered(homeId, msg.sender);
        emit HomeListed(homeId, contentHash, block.timestamp);
    }

    // If you add the Tribal token update function, include event
    function updateTribalTokenAddress(
        address newAddress
    ) external payable onlyOwner {
        address oldAddress = tribalTokenAddress;
        tribalTokenAddress = newAddress;
        emit TribalTokenAddressUpdated(oldAddress, newAddress);
    }

    function updateListing(
        uint256 homeId,
        bytes32 newContentHash,
        uint256 tribalPrice,
        uint256 usdcPrice,
        bool acceptsTribal,
        bool acceptsUsdc
    ) external onlyHomeOwner(homeId) {
        HomeListing storage listing = homeListings[homeId];
        
        listing.contentHash = newContentHash;
        listing.tribalPrice = tribalPrice;
        listing.usdcPrice = usdcPrice;
        listing.acceptsTribal = acceptsTribal;
        listing.acceptsUsdc = acceptsUsdc;

        emit ListingUpdated(homeId, newContentHash, block.timestamp);
    }

    // Add unlistHome function
    function unlistHome(uint256 homeId) external onlyHomeOwner(homeId) {
        HomeListing storage listing = homeListings[homeId];
        if (!listing.isActive) {
            revert HomeNotListed();
        }

        listing.isActive = false;
        
        emit HomeUnlisted(homeId);
    }

    // Add this new function with event
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
}