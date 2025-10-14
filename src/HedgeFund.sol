// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Enumerable, ERC721} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @dev Enumerable queue controlled by the HedgeFund.
contract Queue is ERC721Enumerable, Ownable {
    uint256 private nextId = 1;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) Ownable(msg.sender) {}

    function mint(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = nextId++;
        _safeMint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
    }
}

/// @dev Hedge Fund Share token controlling deposits and queued claims.
contract HedgeFund is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Action {
        Deposit,
        Withdraw
    }

    struct QueuePosition {
        Action action;
        uint256 amount;
        uint256 epoch;
    }

    struct Epoch {
        uint256 sharePrice;
        uint32 timestamp;
    }

    error ZeroAmount();
    error ZeroAddress();
    error InvalidAssetDecimals(uint8 decimals);

    event DepositQueue(address indexed user, uint256 indexed tokenId, uint256 amount, uint256 epoch);
    event WithdrawQueue(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 epoch);
    event DepositClaimed(
        address indexed user, uint256 indexed tokenId, uint256 amount, uint256 mintedShares, uint256 epoch
    );
    event WithdrawClaimed(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 returnedAmount, uint256 epoch
    );
    event EpochContributed(
        uint256 indexed epoch, uint256 tvl, uint256 sharePrice, uint256 timestamp, int256 ownerDelta
    );

    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private immutable ASSET_TO_18 = 1e12;

    Queue public immutable QUEUE;
    IERC20 public immutable ASSET;

    uint256 public currentEpoch;
    uint256 public pendingDeposits;
    uint256 public pendingWithdraw;

    mapping(uint256 => QueuePosition) public positions;
    mapping(uint256 => Epoch) public epochs;

    constructor(address _owner, address _asset) ERC20("Altitude Hedge Fund Share", "AHFS") Ownable(_owner) {
        if (_owner == address(0) || _asset == address(0)) revert ZeroAddress();
        ASSET = IERC20(_asset);
        QUEUE = new Queue("Altitude Hedge Fund Queue", "AHFQ");
    }

    /// @notice Queue asset deposit.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 epochId = currentEpoch + 1;
        _executeClaim(msg.sender);

        ASSET.safeTransferFrom(msg.sender, address(this), amount);
        uint256 tokenId = QUEUE.mint(msg.sender);

        positions[tokenId] = QueuePosition({action: Action.Deposit, amount: amount, epoch: epochId});
        pendingDeposits += amount;

        emit DepositQueue(msg.sender, tokenId, amount, epochId);
    }

    /// @notice Queue share redemption.
    function withdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        uint256 epochId = currentEpoch + 1;
        _executeClaim(msg.sender);

        _transfer(msg.sender, address(this), shares);
        uint256 tokenId = QUEUE.mint(msg.sender);

        positions[tokenId] = QueuePosition({action: Action.Withdraw, amount: shares, epoch: epochId});
        pendingWithdraw += shares;

        emit WithdrawQueue(msg.sender, tokenId, shares, epochId);
    }

    /// @notice Claim all matured queue items.
    function claim() external nonReentrant {
        _executeClaim(msg.sender);
    }

    /// @notice Close epoch with fresh TVL data.
    function contributeEpoch(uint256 tvl) external onlyOwner nonReentrant {
        uint256 epochId = currentEpoch + 1;

        (uint256 sharePrice, int256 delta) = _sharePriceAndDelta(tvl);

        if (delta > 0) {
            ASSET.safeTransferFrom(msg.sender, address(this), uint256(delta));
        } else if (delta < 0) {
            ASSET.safeTransfer(msg.sender, uint256(-delta));
        }

        epochs[epochId] = Epoch({sharePrice: sharePrice, timestamp: uint32(block.timestamp)});
        currentEpoch = epochId;

        emit EpochContributed(epochId, tvl, sharePrice, block.timestamp, delta);
    }

    /// @notice Preview owner cashflow before calling contributeEpoch.
    function preview(uint256 tvl) external view returns (uint256 sharePrice, int256 delta) {
        (sharePrice, delta) = _sharePriceAndDelta(tvl);
    }

    function _sharePriceAndDelta(uint256 tvl) private view returns (uint256 sharePrice, int256 delta) {
        uint256 supply = totalSupply();
        sharePrice = supply == 0 ? PRICE_SCALE : Math.mulDiv(tvl * ASSET_TO_18, PRICE_SCALE, supply);

        uint256 withdrawValue = pendingWithdraw == 0 || sharePrice == 0
            ? 0
            : Math.mulDiv(pendingWithdraw, sharePrice, PRICE_SCALE) / ASSET_TO_18;

        uint256 balance = ASSET.balanceOf(address(this));
        delta = withdrawValue >= balance ? int256(withdrawValue - balance) : -int256(balance - withdrawValue);
    }

    function _executeClaim(address account) private {
        uint256 balance = QUEUE.balanceOf(account);
        if (balance == 0) {
            return;
        }

        uint256[] memory depositTokens = new uint256[](balance);
        uint256[] memory withdrawTokens = new uint256[](balance);
        uint256 depositCount;
        uint256 withdrawCount;

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = QUEUE.tokenOfOwnerByIndex(account, i);
            QueuePosition memory pos = positions[tokenId];
            if (!_isClaimable(pos.epoch)) {
                continue;
            }

            if (pos.action == Action.Deposit) {
                depositTokens[depositCount++] = tokenId;
            } else {
                withdrawTokens[withdrawCount++] = tokenId;
            }
        }

        for (uint256 i = 0; i < depositCount; i++) {
            _settleDeposit(account, depositTokens[i]);
        }

        for (uint256 i = 0; i < withdrawCount; i++) {
            _settleWithdraw(account, withdrawTokens[i]);
        }
    }

    function _settleDeposit(address account, uint256 tokenId) private {
        QueuePosition memory pos = positions[tokenId];
        Epoch memory epoch = epochs[pos.epoch];
        if (epoch.sharePrice == 0) {
            return;
        }

        uint256 amountScaled = pos.amount * ASSET_TO_18;
        uint256 mintedShares = Math.mulDiv(amountScaled, PRICE_SCALE, epoch.sharePrice);

        pendingDeposits -= pos.amount;
        delete positions[tokenId];
        QUEUE.burn(tokenId);

        _mint(account, mintedShares);

        emit DepositClaimed(account, tokenId, pos.amount, mintedShares, pos.epoch);
    }

    function _settleWithdraw(address account, uint256 tokenId) private {
        QueuePosition memory pos = positions[tokenId];
        Epoch memory epoch = epochs[pos.epoch];

        uint256 amountScaled = Math.mulDiv(pos.amount, epoch.sharePrice, PRICE_SCALE);
        uint256 returned = amountScaled / ASSET_TO_18;

        _burn(address(this), pos.amount);
        pendingWithdraw -= pos.amount;
        delete positions[tokenId];
        QUEUE.burn(tokenId);

        if (returned > 0) {
            ASSET.safeTransfer(account, returned);
        }

        emit WithdrawClaimed(account, tokenId, pos.amount, returned, pos.epoch);
    }

    function _isClaimable(uint256 epochId) private view returns (bool) {
        if (epochId == 0 || epochId > currentEpoch) {
            return false;
        }
        return epochs[epochId].sharePrice != 0;
    }
}
