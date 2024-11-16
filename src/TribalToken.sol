// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITribalToken.sol";
import "forge-std/console.sol";


contract TribalToken is ERC20, Ownable2Step, ReentrancyGuard {
    // Custom errors
    error UserAlreadyVerified();
    error UserNotVerified();
    error IncorrectMembershipFee();
    error MembershipExpired(address user);
    error NoFeesToWithdraw();
    error WithdrawalFailed();

    // Yearly membership fee in wei
    uint256 public membershipFee;
    
    enum TransferFailureReason {
        NOT_VERIFIED_SENDER,
        NOT_VERIFIED_RECIPIENT,
        EXPIRED_SENDER,
        EXPIRED_RECIPIENT
    }

    // Add User struct
    struct User {
        bool verified;
        uint256 expiryTimestamp;
    }
    
    // Replace multiple mappings with a single mapping
    mapping(address user => User userData) public users;
    
    // Events
    event UserVerified(address indexed user);
    event MembershipRenewed(address indexed user, uint256 indexed expiryDate);
    event MembershipFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);
    event FeesWithdrawn(address indexed owner, uint256 indexed amount);
    event TokenTransferAttempted(address indexed from, address indexed to, uint256 indexed amount, bool success);
    event TokenTransferFailed(
        address indexed from, 
        address indexed to, 
        uint256 indexed amount, 
        TransferFailureReason reason
    );

    // Add USDC address
    address public immutable usdcAddress;
    
    constructor(uint256 _membershipFee, address _usdcAddress) ERC20("Tribal Community Token", "TRIBAL") Ownable(msg.sender) {
        membershipFee = _membershipFee;
        usdcAddress = _usdcAddress;
    }

    // Admin function to verify users after KYC
    function verifyUser(address user) external onlyOwner {
        if (users[user].verified) {
            revert UserAlreadyVerified();
        }
        users[user].verified = true;
        emit UserVerified(user);
    }

    // Add new modifiers
    modifier onlyVerifiedUser(address user) {
        if (!users[user].verified) {
            revert UserNotVerified();
        }
        _;
    }

    // Function for users to pay membership fee and receive tokens
    function payMembershipFee() external payable onlyVerifiedUser(msg.sender) {
        if (msg.value != membershipFee) {
            revert IncorrectMembershipFee();
        }
        
        users[msg.sender].expiryTimestamp = block.timestamp + 365 days;
        _mint(msg.sender, 1000e18); // 1000 tokens with 18 decimals
        
        emit MembershipRenewed(msg.sender, users[msg.sender].expiryTimestamp);
    }

    // Add new transfer function for any token
    function transferTokens(
        address from,
        address to,
        uint256 amount,
        ITribalToken.PaymentType paymentType
    ) public virtual returns (bool) {
        User memory sender = users[from];
        User memory recipient = users[to];
        uint256 currentTime = block.timestamp;

        // Verify users
        console.log("Sender address:", from);
        console.log("Recipient address:", to);
        console.log("Transfer amount:", amount);
        if (!sender.verified) {
            emit TokenTransferFailed(from, to, amount, TransferFailureReason.NOT_VERIFIED_SENDER);
            revert UserNotVerified();
        }
        if (!recipient.verified) {
            emit TokenTransferFailed(from, to, amount, TransferFailureReason.NOT_VERIFIED_RECIPIENT);
            revert UserNotVerified();
        }

        // Check membership expiry
        if (sender.expiryTimestamp <= currentTime) {
            emit TokenTransferFailed(from, to, amount, TransferFailureReason.EXPIRED_SENDER);
            revert MembershipExpired(from);
        }
        if (recipient.expiryTimestamp <= currentTime) {
            emit TokenTransferFailed(from, to, amount, TransferFailureReason.EXPIRED_RECIPIENT);
            revert MembershipExpired(to);
        }

        bool success;
        if (paymentType == ITribalToken.PaymentType.Tribal) {
            success = this.transferFrom(from, to, amount);
        } else {
            success = IERC20(usdcAddress).transferFrom(from, to, amount);
        }

        emit TokenTransferAttempted(from, to, amount, success);
        return success;
    }

    // Keep original transfer for TRIBAL token compatibility
    function transfer(address to, uint256 amount) 
        public 
        virtual 
        override 
        returns (bool) 
    {
        return transferTokens(msg.sender, to, amount, ITribalToken.PaymentType.Tribal);
    }

    // Admin function to update membership fee
    function setMembershipFee(uint256 newFee) external payable onlyOwner {
        uint256 oldFee = membershipFee;
        if (newFee == oldFee) {
            return;
        }
        membershipFee = newFee;
        emit MembershipFeeUpdated(oldFee, newFee);
    }

    // Updated withdrawal function with reentrancy protection
    function withdrawFees() external nonReentrant payable onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert NoFeesToWithdraw();
        }
        
        // Clear balance before transfer to prevent reentrancy
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) {
            revert WithdrawalFailed();
        }
        
        emit FeesWithdrawn(owner(), balance);
    }

    // Keep this to accept ETH
    receive() external payable {}

    function getBalances(address account) external view returns (uint256 tribalBalance, uint256 usdcBalance) {
        tribalBalance = this.balanceOf(account);
        usdcBalance = IERC20(usdcAddress).balanceOf(account);
        return (tribalBalance, usdcBalance);
    }

    // Add this function to override ERC20's transferFrom
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);  // Check allowance
        _transfer(from, to, amount);
        return true;
    }
}
