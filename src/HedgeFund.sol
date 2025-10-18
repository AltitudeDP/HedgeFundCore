// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Queue} from "./Queue.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20, IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

/// @title Altitude Hedge Fund
contract HedgeFund is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Action {
        Deposit,
        Withdraw
    }

    struct QueuePosition {
        Action action;
        uint256 amount;
        uint64 epoch;
    }

    struct Epoch {
        uint256 sharePrice;
        uint32 timestamp;
    }

    struct FeeBreakdown {
        uint256 managementAssets;
        uint256 performanceAssets;
        uint256 managementShares;
        uint256 performanceShares;
    }

    error ZeroAmount();
    error ZeroAddress();
    error InvalidAssetDecimals(uint8 decimals);
    error FeeTooHigh();

    event DepositQueued(address indexed user, uint256 indexed tokenId, uint256 assets, uint64 epoch);
    event WithdrawQueued(address indexed user, uint256 indexed tokenId, uint256 shares, uint64 epoch);
    event DepositClaimed(
        address indexed user, uint256 indexed tokenId, uint256 assets, uint256 mintedShares, uint64 epoch
    );
    event WithdrawClaimed(
        address indexed user, uint256 indexed tokenId, uint256 shares, uint256 returnedAssets, uint64 epoch
    );
    event FeesUpdated(uint64 managementFeeWad, uint64 performanceFeeWad);
    event EpochContributed(
        uint64 indexed epoch,
        uint256 nav,
        uint256 sharePrice,
        uint256 highWaterMark,
        uint32 timestamp,
        int256 ownerDelta,
        uint256 managementFeeAssets,
        uint256 performanceFeeAssets,
        uint256 managementFeeShares,
        uint256 performanceFeeShares
    );

    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private constant YEAR = 365 days;

    Queue public immutable QUEUE;
    IERC20 public immutable ASSET;
    uint256 public immutable ASSET_SCALE;

    uint64 public currentEpoch;
    uint64 public managementFeeWad;
    uint64 public performanceFeeWad;

    uint256 public highWaterMark;
    uint256 public pendingDeposits;
    uint256 public pendingWithdraw;

    mapping(uint256 => QueuePosition) public positions;
    mapping(uint64 => Epoch) public epochs;

    constructor(
        address owner_,
        address asset_,
        string memory shareName_,
        string memory shareSymbol_,
        string memory queueName_,
        string memory queueSymbol_
    ) ERC20(shareName_, shareSymbol_) Ownable(owner_) {
        if (owner_ == address(0) || asset_ == address(0)) revert ZeroAddress();

        ASSET = IERC20(asset_);
        uint8 decimals_ = IERC20Metadata(asset_).decimals();
        if (decimals_ > 18) revert InvalidAssetDecimals(decimals_);
        ASSET_SCALE = 10 ** (18 - decimals_);

        QUEUE = new Queue(queueName_, queueSymbol_);
        managementFeeWad = 2e16; // 2%
        performanceFeeWad = 2e17; // 20%
        highWaterMark = PRICE_SCALE;
        epochs[0] = Epoch({sharePrice: PRICE_SCALE, timestamp: SafeCast.toUint32(block.timestamp)});
    }

    /// @notice Owner may tune fee rates (expressed in WAD).
    function setFees(uint64 managementFeeWad_, uint64 performanceFeeWad_) external onlyOwner {
        if (managementFeeWad_ > 1e17 || performanceFeeWad_ > 5e17) revert FeeTooHigh();
        if (managementFeeWad_ == 0 || performanceFeeWad_ == 0) revert ZeroAmount();

        managementFeeWad = managementFeeWad_;
        performanceFeeWad = performanceFeeWad_;

        emit FeesUpdated(managementFeeWad_, performanceFeeWad_);
    }

    /// @notice Queue an asset deposit.
    function deposit(uint256 assets) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        uint64 epochId = currentEpoch + 1;
        _executeClaim(msg.sender);

        ASSET.safeTransferFrom(msg.sender, address(this), assets);
        uint256 tokenId = QUEUE.mint(msg.sender);

        positions[tokenId] = QueuePosition({action: Action.Deposit, amount: assets, epoch: epochId});
        pendingDeposits += assets;

        emit DepositQueued(msg.sender, tokenId, assets, epochId);
    }

    /// @notice Queue a share redemption.
    function withdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        uint64 epochId = currentEpoch + 1;
        _executeClaim(msg.sender);

        _transfer(msg.sender, address(this), shares);
        uint256 tokenId = QUEUE.mint(msg.sender);

        positions[tokenId] = QueuePosition({action: Action.Withdraw, amount: shares, epoch: epochId});
        pendingWithdraw += shares;

        emit WithdrawQueued(msg.sender, tokenId, shares, epochId);
    }

    /// @notice Claim every matured queue position.
    function claim() external nonReentrant {
        _executeClaim(msg.sender);
    }

    /// @notice Preview share price, owner cashflow and the next high-water mark.
    function preview(uint256 nav)
        external
        view
        returns (uint256 sharePrice, int256 delta, uint256 nextHighWaterMark, FeeBreakdown memory fees)
    {
        (sharePrice, delta, fees, nextHighWaterMark) = _sharePriceAndDelta(nav);
    }

    /// @notice Owner pushes the latest NAV and settles fees.
    function contributeEpoch(uint256 nav) external onlyOwner nonReentrant {
        uint64 epochId = currentEpoch + 1;
        (uint256 sharePrice, int256 delta, FeeBreakdown memory fees, uint256 nextHighWaterMark) =
            _sharePriceAndDelta(nav);

        if (delta > 0) {
            ASSET.safeTransferFrom(msg.sender, address(this), SafeCast.toUint256(delta));
        } else if (delta < 0) {
            ASSET.safeTransfer(msg.sender, SafeCast.toUint256(-delta));
        }

        uint256 ownerShares = fees.managementShares + fees.performanceShares;
        if (ownerShares != 0) {
            _mint(owner(), ownerShares);
        }

        epochs[epochId] = Epoch({sharePrice: sharePrice, timestamp: SafeCast.toUint32(block.timestamp)});
        currentEpoch = epochId;
        highWaterMark = nextHighWaterMark;

        emit EpochContributed(
            epochId,
            nav,
            sharePrice,
            nextHighWaterMark,
            SafeCast.toUint32(block.timestamp),
            delta,
            fees.managementAssets,
            fees.performanceAssets,
            fees.managementShares,
            fees.performanceShares
        );
    }

    function _sharePriceAndDelta(uint256 nav)
        private
        view
        returns (uint256 sharePrice, int256 delta, FeeBreakdown memory fees, uint256 nextHighWaterMark)
    {
        uint256 supplyBefore = totalSupply();
        uint256 previousHighWaterMark = highWaterMark;
        uint256 supplyAfter = supplyBefore;
        uint256 sharePriceAfter =
            supplyBefore == 0 ? PRICE_SCALE : Math.mulDiv(nav * ASSET_SCALE, PRICE_SCALE, supplyBefore);

        if (supplyBefore != 0) {
            Epoch memory prevEpoch = epochs[currentEpoch];

            if (prevEpoch.timestamp != 0 && sharePriceAfter != 0) {
                uint256 dt = block.timestamp - uint256(prevEpoch.timestamp);
                if (dt != 0) {
                    uint256 managementAccrual = Math.mulDiv(managementFeeWad, dt, YEAR);
                    uint256 scaleAfter = PRICE_SCALE - managementAccrual;
                    sharePriceAfter = Math.mulDiv(sharePriceAfter, scaleAfter, PRICE_SCALE);
                    uint256 minted = Math.mulDiv(supplyAfter, managementAccrual, scaleAfter);
                    fees.managementShares = minted;
                    supplyAfter += minted;
                    fees.managementAssets = Math.mulDiv(minted, sharePriceAfter, PRICE_SCALE * ASSET_SCALE);
                }
            }

            if (sharePriceAfter > previousHighWaterMark) {
                uint256 profitAbove = sharePriceAfter - previousHighWaterMark;
                uint256 feePerShare = Math.mulDiv(profitAbove, performanceFeeWad, PRICE_SCALE);
                if (feePerShare >= sharePriceAfter) feePerShare = sharePriceAfter - 1;
                if (feePerShare != 0) {
                    sharePriceAfter -= feePerShare;
                    uint256 minted = Math.mulDiv(supplyAfter, feePerShare, sharePriceAfter);
                    fees.performanceShares = minted;
                    supplyAfter += minted;
                    fees.performanceAssets = Math.mulDiv(minted, sharePriceAfter, PRICE_SCALE * ASSET_SCALE);
                }
            }

            sharePrice = Math.mulDiv(nav * ASSET_SCALE, PRICE_SCALE, supplyAfter);
            nextHighWaterMark = sharePrice > previousHighWaterMark ? sharePrice : previousHighWaterMark;
        } else {
            sharePrice = PRICE_SCALE;
            nextHighWaterMark = previousHighWaterMark > PRICE_SCALE ? previousHighWaterMark : PRICE_SCALE;
        }

        uint256 withdrawValue = pendingWithdraw == 0 || sharePrice == 0
            ? 0
            : Math.mulDiv(pendingWithdraw, sharePrice, PRICE_SCALE) / ASSET_SCALE;

        uint256 balance = ASSET.balanceOf(address(this));
        if (withdrawValue >= balance) {
            delta = SafeCast.toInt256(withdrawValue - balance);
        } else {
            delta = -SafeCast.toInt256(balance - withdrawValue);
        }
    }

    function _executeClaim(address account) private {
        uint256 balance = QUEUE.balanceOf(account);
        if (balance == 0) return;

        uint256[] memory depositTokens = new uint256[](balance);
        uint256[] memory withdrawTokens = new uint256[](balance);
        uint256 depositCount;
        uint256 withdrawCount;

        for (uint256 i; i < balance; ++i) {
            uint256 tokenId = QUEUE.tokenOfOwnerByIndex(account, i);
            QueuePosition memory pos = positions[tokenId];
            if (!_isClaimable(pos.epoch)) continue;
            if (pos.action == Action.Deposit) {
                depositTokens[depositCount++] = tokenId;
            } else {
                withdrawTokens[withdrawCount++] = tokenId;
            }
        }

        for (uint256 i; i < depositCount; ++i) {
            _settleDeposit(account, depositTokens[i]);
        }
        for (uint256 i; i < withdrawCount; ++i) {
            _settleWithdraw(account, withdrawTokens[i]);
        }
    }

    function _settleDeposit(address account, uint256 tokenId) private {
        QueuePosition memory pos = positions[tokenId];
        Epoch memory epoch = epochs[pos.epoch];

        uint256 amountScaled = pos.amount * ASSET_SCALE;
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
        uint256 returned = amountScaled / ASSET_SCALE;

        _burn(address(this), pos.amount);
        pendingWithdraw -= pos.amount;
        delete positions[tokenId];
        QUEUE.burn(tokenId);

        if (returned != 0) {
            ASSET.safeTransfer(account, returned);
        }
        emit WithdrawClaimed(account, tokenId, pos.amount, returned, pos.epoch);
    }

    function _isClaimable(uint64 epochId) private view returns (bool) {
        return epochId != 0 && epochId <= currentEpoch && epochs[epochId].sharePrice != 0;
    }
}
