// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Queue} from "./Queue.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20, IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @title Altitude Hedge Fund
contract HedgeFund is ERC20, Ownable, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    enum Action {
        Deposit,
        Withdraw
    }

    struct QueuePosition {
        uint256 amount;
        uint64 epoch;
        Action action;
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
    error InvalidSharePrice();

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
    uint256 private constant MAX_MANAGEMENT_INTERVAL = 365 days;
    uint256 private immutable ASSET_SCALE_PRICE_SCALE;

    Queue public immutable QUEUE;
    IERC20 public immutable ASSET;

    uint64 public currentEpoch;
    uint64 public managementFeeWad;
    uint64 public performanceFeeWad;

    uint256 public highWaterMark;
    uint256 public pendingDeposits;
    uint256 public pendingWithdraw;
    uint256 public withdrawReserveAssets;

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
        ASSET_SCALE_PRICE_SCALE = PRICE_SCALE * 10 ** (18 - decimals_);

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

    /// @notice Owner may pause new deposits.
    function pauseDeposits() external onlyOwner {
        _pause();
    }

    /// @notice Owner resumes deposits.
    function unpauseDeposits() external onlyOwner {
        _unpause();
    }

    /// @notice Queue an asset deposit.
    function deposit(uint256 assets) external nonReentrant whenNotPaused {
        if (assets == 0) revert ZeroAmount();
        uint64 epochId = currentEpoch + 1;
        _executeClaim(msg.sender);

        ASSET.safeTransferFrom(msg.sender, address(this), assets);
        uint256 tokenId = QUEUE.mint(msg.sender);

        positions[tokenId] = QueuePosition({amount: assets, epoch: epochId, action: Action.Deposit});
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

        positions[tokenId] = QueuePosition({amount: shares, epoch: epochId, action: Action.Withdraw});
        pendingWithdraw += shares;

        emit WithdrawQueued(msg.sender, tokenId, shares, epochId);
    }

    /// @notice Claim every matured queue position.
    function claim() external nonReentrant returns (uint256 shares, uint256 assets) {
        (shares, assets) = _executeClaim(msg.sender);
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
            _mint(msg.sender, ownerShares);
        }

        epochs[epochId] = Epoch({sharePrice: sharePrice, timestamp: SafeCast.toUint32(block.timestamp)});
        currentEpoch = epochId;
        highWaterMark = nextHighWaterMark;
        withdrawReserveAssets += Math.mulDiv(pendingWithdraw, sharePrice, ASSET_SCALE_PRICE_SCALE);
        pendingWithdraw = 0;

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
            supplyBefore == 0 ? PRICE_SCALE : Math.mulDiv(nav, ASSET_SCALE_PRICE_SCALE, supplyBefore);
        if (sharePriceAfter == 0 && supplyBefore != 0) revert InvalidSharePrice();

        if (supplyBefore != 0) {
            Epoch memory prevEpoch = epochs[currentEpoch];
            if (prevEpoch.timestamp != 0) {
                uint256 dt = block.timestamp - uint256(prevEpoch.timestamp);
                if (dt != 0) {
                    if (dt > MAX_MANAGEMENT_INTERVAL) dt = MAX_MANAGEMENT_INTERVAL;
                    uint256 managementAccrual = Math.mulDiv(managementFeeWad, dt, YEAR);
                    uint256 scaleAfter = PRICE_SCALE - managementAccrual;
                    sharePriceAfter = Math.mulDiv(sharePriceAfter, scaleAfter, PRICE_SCALE);
                    uint256 minted = Math.mulDiv(supplyAfter, managementAccrual, scaleAfter);
                    fees.managementShares = minted;
                    supplyAfter += minted;
                    fees.managementAssets = Math.mulDiv(minted, sharePriceAfter, ASSET_SCALE_PRICE_SCALE);
                }
            }

            if (sharePriceAfter > previousHighWaterMark) {
                uint256 profitAbove = sharePriceAfter - previousHighWaterMark;
                uint256 feePerShare = Math.mulDiv(profitAbove, performanceFeeWad, PRICE_SCALE);
                if (feePerShare != 0) {
                    sharePriceAfter -= feePerShare;
                    uint256 minted = Math.mulDiv(supplyAfter, feePerShare, sharePriceAfter);
                    fees.performanceShares = minted;
                    supplyAfter += minted;
                    fees.performanceAssets = Math.mulDiv(minted, sharePriceAfter, ASSET_SCALE_PRICE_SCALE);
                }
            }

            sharePrice = supplyAfter == 0 ? PRICE_SCALE : Math.mulDiv(nav, ASSET_SCALE_PRICE_SCALE, supplyAfter);
            nextHighWaterMark = sharePrice > previousHighWaterMark ? sharePrice : previousHighWaterMark;
        } else {
            sharePrice = PRICE_SCALE;
            nextHighWaterMark = PRICE_SCALE;
        }

        uint256 sharesValue =
            pendingWithdraw == 0 ? 0 : Math.mulDiv(pendingWithdraw, sharePrice, ASSET_SCALE_PRICE_SCALE);
        uint256 withdrawValue = sharesValue + withdrawReserveAssets;

        uint256 balance = ASSET.balanceOf(address(this));
        if (withdrawValue >= balance) {
            delta = SafeCast.toInt256(withdrawValue - balance);
        } else {
            delta = -SafeCast.toInt256(balance - withdrawValue);
        }
    }

    function _executeClaim(address account) private returns (uint256 shares, uint256 assets) {
        uint256 balance = QUEUE.balanceOf(account);
        if (balance == 0) return (0, 0);

        for (uint256 i = balance; i != 0; i--) {
            uint256 tokenId = QUEUE.tokenOfOwnerByIndex(account, i - 1);
            QueuePosition memory pos = positions[tokenId];
            if (epochs[pos.epoch].sharePrice == 0) continue;
            if (pos.action == Action.Deposit) {
                shares += _settleDeposit(account, tokenId);
            } else {
                assets += _settleWithdraw(account, tokenId);
            }
        }
    }

    function _settleDeposit(address account, uint256 tokenId) private returns (uint256 shares) {
        QueuePosition memory pos = positions[tokenId];
        Epoch memory epoch = epochs[pos.epoch];

        shares = Math.mulDiv(pos.amount, ASSET_SCALE_PRICE_SCALE, epoch.sharePrice);

        pendingDeposits -= pos.amount;
        delete positions[tokenId];
        QUEUE.burn(tokenId);

        _mint(account, shares);
        emit DepositClaimed(account, tokenId, pos.amount, shares, pos.epoch);
    }

    function _settleWithdraw(address account, uint256 tokenId) private returns (uint256 assets) {
        QueuePosition memory pos = positions[tokenId];
        Epoch memory epoch = epochs[pos.epoch];

        assets = Math.mulDiv(pos.amount, epoch.sharePrice, ASSET_SCALE_PRICE_SCALE);

        withdrawReserveAssets -= assets;
        _burn(address(this), pos.amount);
        delete positions[tokenId];
        QUEUE.burn(tokenId);

        ASSET.safeTransfer(account, assets);
        emit WithdrawClaimed(account, tokenId, pos.amount, assets, pos.epoch);
    }
}
