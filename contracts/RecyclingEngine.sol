// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Ownable2StepLite.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRegistryEngine {
    function assets(address token)
        external
        view
        returns (bool listed, bool enabled, uint8 decimals, uint256 unitsPer1e18Native, uint256 capUnits);
}

interface ILedgerEngine {
    function recyclableBalance(address beneficiary, address token) external view returns (uint256);
    function consume(address beneficiary, address token, uint256 units) external;
}

interface IFeeRouterEngine {
    function route(address beneficiary) external payable returns (uint256 recycleAmount);
}

/**
 * RecyclingEngine (Ledger + Router model)
 * - Consumes accounting-only "units" from ledger (no token approvals here)
 * - Routes native fee via router; reward rail remains in engine to be claimed
 * - Distributes reward rail to weight holders (accNativePerWeight)
 * - Mints weight from recycleRail at currentWeightPrice()
 *
 * Additions:
 * - quoteUnitsToConsume() and quoteNativeForUnitsCeil() for UI + correctness
 */
contract RecyclingEngine is Ownable2StepLite, ReentrancyGuard {
    error ENGINE_ZERO_ADDRESS();
    error ENGINE_ASSET_NOT_ENABLED();
    error ENGINE_NO_VALUE();
    error ENGINE_INSUFFICIENT_ALLOWANCE();
    error ENGINE_PRICE_ZERO();
    error ENGINE_PARAM_OOB();
    error ENGINE_CLAIM_TRANSFER_FAILED();
    error ENGINE_BAD_UNITS();          // computed units == 0
    error ENGINE_ROUTER_MISMATCH();    // reported != received
    error ENGINE_ROUTER_ZERO_RAIL();   // received == 0 (strict mode)
    error ENGINE_DIV_BY_ZERO();        // rate == 0 in registry

    event ParamsSet(uint256 baseWeightPriceWei, uint256 decayPerDayPPM, uint256 linearGrowthSlopeWeiPerDay);

    event Recycled(
        address indexed beneficiary,
        address indexed token,
        uint256 nativePaidWei,
        uint256 unitsConsumed,
        uint256 recycleRailWei,
        uint256 weightMinted
    );

    event Claimed(address indexed user, uint256 amountWei);

    uint256 public constant ACC_SCALE = 1e18;
    uint256 public constant PPM_DENOM = 1_000_000;

    IRegistryEngine public immutable registry;
    ILedgerEngine public immutable ledger;
    IFeeRouterEngine public immutable router;

    uint256 public baseWeightPriceWei;
    uint256 public decayPerDayPPM;
    uint256 public linearGrowthSlopeWeiPerDay;

    uint64 public immutable deployedAt;

    uint256 public totalWeight;
    mapping(address => uint256) public weightOf;

    uint256 public accNativePerWeight;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public claimable;

    constructor(
        address registry_,
        address ledger_,
        address router_,
        uint256 baseWeightPriceWei_,
        uint256 decayPerDayPPM_,
        uint256 linearGrowthSlopeWeiPerDay_,
        address initialOwner
    ) Ownable2StepLite(initialOwner) {
        if (registry_ == address(0) || ledger_ == address(0) || router_ == address(0)) revert ENGINE_ZERO_ADDRESS();

        registry = IRegistryEngine(registry_);
        ledger = ILedgerEngine(ledger_);
        router = IFeeRouterEngine(router_);

        deployedAt = uint64(block.timestamp);
        _setParams(baseWeightPriceWei_, decayPerDayPPM_, linearGrowthSlopeWeiPerDay_);
    }

    receive() external payable {}

    function setParams(
        uint256 baseWeightPriceWei_,
        uint256 decayPerDayPPM_,
        uint256 linearGrowthSlopeWeiPerDay_
    ) external onlyOwner {
        _setParams(baseWeightPriceWei_, decayPerDayPPM_, linearGrowthSlopeWeiPerDay_);
    }

    function _setParams(
        uint256 baseWeightPriceWei_,
        uint256 decayPerDayPPM_,
        uint256 linearGrowthSlopeWeiPerDay_
    ) internal {
        if (baseWeightPriceWei_ == 0) revert ENGINE_PRICE_ZERO();
        if (decayPerDayPPM_ > PPM_DENOM) revert ENGINE_PARAM_OOB();

        baseWeightPriceWei = baseWeightPriceWei_;
        decayPerDayPPM = decayPerDayPPM_;
        linearGrowthSlopeWeiPerDay = linearGrowthSlopeWeiPerDay_;

        emit ParamsSet(baseWeightPriceWei_, decayPerDayPPM_, linearGrowthSlopeWeiPerDay_);
    }

    function currentWeightPrice() public view returns (uint256) {
        uint256 elapsed = block.timestamp - uint256(deployedAt);
        uint256 daysElapsed = elapsed / 1 days;

        uint256 decay = (baseWeightPriceWei * decayPerDayPPM * daysElapsed) / PPM_DENOM;
        uint256 growth = linearGrowthSlopeWeiPerDay * daysElapsed;

        uint256 price = baseWeightPriceWei + growth;
        if (decay >= price) return 1;
        return price - decay;
    }

    /*//////////////////////////////////////////////////////////////
                                QUOTES
    //////////////////////////////////////////////////////////////*/

    /// @notice Quote units consumed for a given native amount (same formula used in recycle()).
    function quoteUnitsToConsume(address token, uint256 nativeWei) external view returns (uint256 units) {
        (, , , uint256 unitsPer1e18Native, ) = registry.assets(token);
        if (unitsPer1e18Native == 0) revert ENGINE_DIV_BY_ZERO();
        units = (nativeWei * unitsPer1e18Native) / 1e18;
    }

    /// @notice Quote *minimum* native required to consume `units` (ceil division).
    function quoteNativeForUnitsCeil(address token, uint256 units) external view returns (uint256 nativeWei) {
        (bool listed, bool enabled, , uint256 unitsPer1e18Native, ) = registry.assets(token);
        if (!listed || !enabled) revert ENGINE_ASSET_NOT_ENABLED();
        if (unitsPer1e18Native == 0) revert ENGINE_DIV_BY_ZERO();
        // ceil(units * 1e18 / rate)
        nativeWei = (units * 1e18 + (unitsPer1e18Native - 1)) / unitsPer1e18Native;
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTION
    //////////////////////////////////////////////////////////////*/

    function recycle(address token) external payable nonReentrant {
        address beneficiary = msg.sender;
        uint256 nativePaid = msg.value;
        if (nativePaid == 0) revert ENGINE_NO_VALUE();

        (bool listed, bool enabled, , uint256 unitsPer1e18Native, ) = registry.assets(token);
        if (!listed || !enabled) revert ENGINE_ASSET_NOT_ENABLED();
        if (unitsPer1e18Native == 0) revert ENGINE_DIV_BY_ZERO();

        uint256 unitsToConsume = (nativePaid * unitsPer1e18Native) / 1e18;
        if (unitsToConsume == 0) revert ENGINE_BAD_UNITS();

        uint256 bal = ledger.recyclableBalance(beneficiary, token);
        if (bal < unitsToConsume) revert ENGINE_INSUFFICIENT_ALLOWANCE();

        _harvest(beneficiary);

        // Consume first; if router fails, tx reverts atomically
        ledger.consume(beneficiary, token, unitsToConsume);

        // Solvency invariant: trust balance delta, not router return
        uint256 balBefore = address(this).balance - nativePaid; // exclude msg.value already included in balance
        uint256 reported = router.route{value: nativePaid}(beneficiary);
        uint256 received = address(this).balance - balBefore;

        if (received != reported) revert ENGINE_ROUTER_MISMATCH();
        if (received == 0) revert ENGINE_ROUTER_ZERO_RAIL();

        uint256 recycleRail = received;

        if (totalWeight > 0) {
            accNativePerWeight += (recycleRail * ACC_SCALE) / totalWeight;
        }

        uint256 price = currentWeightPrice();
        if (price == 0) revert ENGINE_PRICE_ZERO();

        uint256 weightMinted = (recycleRail * ACC_SCALE) / price;
        if (weightMinted != 0) {
            totalWeight += weightMinted;
            weightOf[beneficiary] += weightMinted;
        }

        rewardDebt[beneficiary] = (weightOf[beneficiary] * accNativePerWeight) / ACC_SCALE;

        emit Recycled(beneficiary, token, nativePaid, unitsToConsume, recycleRail, weightMinted);
    }

    function claim() external nonReentrant {
        address user = msg.sender;
        _harvest(user);

        uint256 amt = claimable[user];
        if (amt == 0) return;

        claimable[user] = 0;

        (bool ok, ) = user.call{value: amt}("");
        if (!ok) revert ENGINE_CLAIM_TRANSFER_FAILED();

        emit Claimed(user, amt);
    }

    function pending(address user) external view returns (uint256) {
        uint256 w = weightOf[user];
        uint256 accrued = (w * accNativePerWeight) / ACC_SCALE;
        uint256 debt = rewardDebt[user];
        uint256 delta = accrued > debt ? (accrued - debt) : 0;
        return claimable[user] + delta;
    }

    function _harvest(address user) internal {
        uint256 w = weightOf[user];
        uint256 accrued = (w * accNativePerWeight) / ACC_SCALE;
        uint256 debt = rewardDebt[user];

        if (accrued > debt) {
            claimable[user] += (accrued - debt);
        }

        rewardDebt[user] = accrued;
    }
}
