pragma solidity 0.4.25;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./SafeDecimalMath.sol";
import "./MixinResolver.sol";
import "./interfaces/IShadows.sol";
import "./interfaces/IFeePool.sol";
import "./interfaces/IShadowsState.sol";
import "./interfaces/IExchanger.sol";


contract Issuer is MixinResolver {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    bytes32 private constant xUSD = "xUSD";

    constructor(address _owner, address _resolver) public MixinResolver(_owner, _resolver) {}

    /* ========== VIEWS ========== */
    function shadows() internal view returns (IShadows) {
        return IShadows(resolver.requireAndGetAddress("Shadows", "Missing Shadows address"));
    }

    function exchanger() internal view returns (IExchanger) {
        return IExchanger(resolver.requireAndGetAddress("Exchanger", "Missing Exchanger address"));
    }

    function shadowsState() internal view returns (IShadowsState) {
        return IShadowsState(resolver.requireAndGetAddress("ShadowsState", "Missing ShadowsState address"));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(resolver.requireAndGetAddress("FeePool", "Missing FeePool address"));
    }

    /* ========== SETTERS ========== */

    /* ========== MUTATIVE FUNCTIONS ========== */

    function issueSynths(address from, uint amount)
        external
        onlyShadows
    // No need to check if price is stale, as it is checked in issuableSynths.
    {
        // Get remaining issuable in xUSD and existingDebt
        (uint maxIssuable, uint existingDebt) = shadows().remainingIssuableSynths(from);
        require(amount <= maxIssuable, "Amount too large");

        // Keep track of the debt they're about to create (in xUSD)
        _addToDebtRegister(from, amount, existingDebt);

        // Create their synths
        shadows().synths(xUSD).issue(from, amount);

        // Store their locked DOWS amount to determine their fee % for the period
        _appendAccountIssuanceRecord(from);
    }

    function issueMaxSynths(address from) external onlyShadows {
        // Figure out the maximum we can issue in that currency
        (uint maxIssuable, uint existingDebt) = shadows().remainingIssuableSynths(from);

        // Keep track of the debt they're about to create
        _addToDebtRegister(from, maxIssuable, existingDebt);

        // Create their synths
        shadows().synths(xUSD).issue(from, maxIssuable);

        // Store their locked DOWS amount to determine their fee % for the period
        _appendAccountIssuanceRecord(from);
    }

    function burnSynths(address from, uint amount)
        external
        onlyShadows
    // No need to check for stale rates as effectiveValue checks rates
    {
        IShadows _shadows = shadows();
        IExchanger _exchanger = exchanger();

        // First settle anything pending into xUSD as burning or issuing impacts the size of the debt pool
        (, uint refunded) = _exchanger.settle(from, xUSD);

        // How much debt do they have?
        uint existingDebt = _shadows.debtBalanceOf(from, xUSD);

        require(existingDebt > 0, "No debt to forgive");

        uint debtToRemoveAfterSettlement = _exchanger.calculateAmountAfterSettlement(from, xUSD, amount, refunded);

        // If they're trying to burn more debt than they actually owe, rather than fail the transaction, let's just
        // clear their debt and leave them be.
        uint amountToRemove = existingDebt < debtToRemoveAfterSettlement ? existingDebt : debtToRemoveAfterSettlement;

        // Remove their debt from the ledger
        _removeFromDebtRegister(from, amountToRemove, existingDebt);

        uint amountToBurn = amountToRemove;

        // synth.burn does a safe subtraction on balance (so it will revert if there are not enough synths).
        _shadows.synths(xUSD).burn(from, amountToBurn);

        // Store their debtRatio against a feeperiod to determine their fee/rewards % for the period
        _appendAccountIssuanceRecord(from);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice Store in the FeePool the users current debt value in the system.
      * @dev debtBalanceOf(messageSender, "xUSD") to be used with totalIssuedSynthsExcludeEtherCollateral("xUSD") to get
     *  users % of the system within a feePeriod.
     */
    function _appendAccountIssuanceRecord(address from) internal {
        uint initialDebtOwnership;
        uint debtEntryIndex;
        (initialDebtOwnership, debtEntryIndex) = shadowsState().issuanceData(from);

        feePool().appendAccountIssuanceRecord(from, initialDebtOwnership, debtEntryIndex);
    }

    /**
     * @notice Function that registers new synth as they are issued. Calculate delta to append to shadowsState.
     * @dev Only internal calls from shadows address.
     * @param amount The amount of synths to register with a base of UNIT
     */
    function _addToDebtRegister(address from, uint amount, uint existingDebt) internal {
        IShadowsState state = shadowsState();

        // What is the value of all issued synths of the system, excluding ether collateral synths (priced in xUSD)?
        uint totalDebtIssued = shadows().totalIssuedSynthsExcludeEtherCollateral(xUSD);

        // What will the new total be including the new value?
        uint newTotalDebtIssued = amount.add(totalDebtIssued);

        // What is their percentage (as a high precision int) of the total debt?
        uint debtPercentage = amount.divideDecimalRoundPrecise(newTotalDebtIssued);

        // And what effect does this percentage change have on the global debt holding of other issuers?
        // The delta specifically needs to not take into account any existing debt as it's already
        // accounted for in the delta from when they issued previously.
        // The delta is a high precision integer.
        uint delta = SafeDecimalMath.preciseUnit().sub(debtPercentage);

        // And what does their debt ownership look like including this previous stake?
        if (existingDebt > 0) {
            debtPercentage = amount.add(existingDebt).divideDecimalRoundPrecise(newTotalDebtIssued);
        }

        // Are they a new issuer? If so, record them.
        if (existingDebt == 0) {
            state.incrementTotalIssuerCount();
        }

        // Save the debt entry parameters
        state.setCurrentIssuanceData(from, debtPercentage);

        // And if we're the first, push 1 as there was no effect to any other holders, otherwise push
        // the change for the rest of the debt holders. The debt ledger holds high precision integers.
        if (state.debtLedgerLength() > 0) {
            state.appendDebtLedgerValue(state.lastDebtLedgerEntry().multiplyDecimalRoundPrecise(delta));
        } else {
            state.appendDebtLedgerValue(SafeDecimalMath.preciseUnit());
        }
    }

    /**
     * @notice Remove a debt position from the register
     * @param amount The amount (in UNIT base) being presented in xUSDs
     * @param existingDebt The existing debt (in UNIT base) of address presented in xUSDs
     */
    function _removeFromDebtRegister(address from, uint amount, uint existingDebt) internal {
        IShadowsState state = shadowsState();

        uint debtToRemove = amount;

        // What is the value of all issued synths of the system, excluding ether collateral synths (priced in xUSDs)?
        uint totalDebtIssued = shadows().totalIssuedSynthsExcludeEtherCollateral(xUSD);

        // What will the new total after taking out the withdrawn amount
        uint newTotalDebtIssued = totalDebtIssued.sub(debtToRemove);

        uint delta = 0;

        // What will the debt delta be if there is any debt left?
        // Set delta to 0 if no more debt left in system after user
        if (newTotalDebtIssued > 0) {
            // What is the percentage of the withdrawn debt (as a high precision int) of the total debt after?
            uint debtPercentage = debtToRemove.divideDecimalRoundPrecise(newTotalDebtIssued);

            // And what effect does this percentage change have on the global debt holding of other issuers?
            // The delta specifically needs to not take into account any existing debt as it's already
            // accounted for in the delta from when they issued previously.
            delta = SafeDecimalMath.preciseUnit().add(debtPercentage);
        }

        // Are they exiting the system, or are they just decreasing their debt position?
        if (debtToRemove == existingDebt) {
            state.setCurrentIssuanceData(from, 0);
            state.decrementTotalIssuerCount();
        } else {
            // What percentage of the debt will they be left with?
            uint newDebt = existingDebt.sub(debtToRemove);
            uint newDebtPercentage = newDebt.divideDecimalRoundPrecise(newTotalDebtIssued);

            // Store the debt percentage and debt ledger as high precision integers
            state.setCurrentIssuanceData(from, newDebtPercentage);
        }

        // Update our cumulative ledger. This is also a high precision integer.
        state.appendDebtLedgerValue(state.lastDebtLedgerEntry().multiplyDecimalRoundPrecise(delta));
    }

    /* ========== MODIFIERS ========== */

    modifier onlyShadows() {
        require(msg.sender == address(shadows()), "Issuer: Only the shadows contract can perform this action");
        _;
    }
}
