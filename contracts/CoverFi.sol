// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@uma/core/contracts/common/implementation/AddressWhitelist.sol";
import "@uma/core/contracts/oracle/implementation/Constants.sol";
import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/oracle/interfaces/FinderInterface.sol";
import "@uma/core/contracts/oracle/interfaces/OptimisticOracleV2Interface.sol";

import "./interfaces/IIbAlluo.sol";

/**
 * @title Insurance Arbitrator Contract
 * @notice This example implementation allows insurer to issue insurance policy by depositing insured amount,
 * designating the insured beneficiary and describing insured event. At any time anyone can submit claim that the insured
 * event has occurred by posting oracle bonding. Insurance Arbitrator resolves the claim through Optimistic Oracle by
 * passing templated question with insured event description in ancillary data. If the claim is confirmed this contract
 * automatically pays out insurance coverage to the insured beneficiary. If the claim is rejected policy continues to be
 * active ready for the subsequent claim attempts.
 */
contract CoverFiGoerli is Testable, Ownable {
    using SafeERC20 for IERC20;

    /******************************************
     *  STATE VARIABLES AND DATA STRUCTURES   *
     ******************************************/

    uint256 public totalInsurancePremium;
    

    // Stores state and parameters of insurance policy.
    struct InsurancePolicy {
        bool claimInitiated; // Claim state preventing simultaneous claim attempts.
        string insuredEvent; // Short description of insured event.
        string protocolAddress;
        address insuredAddress; // Beneficiary address eligible for insurance compensation.
        uint256 insuredAmount; // Amount of insurance coverage.
        uint256 premium; // Premium
    }

    struct AllowedInsurance {
        string name;
        uint256 premium; //Percentage
    }

    // References all active insurance policies by policyId.
    mapping(bytes32 => InsurancePolicy) public insurancePolicies;

    // Mapping from user address to policyId array (a user can have multiple active policies).
    mapping(address => bytes32[]) public userPolicies;

    // Maps hash of initiated claims to their policyId.
    // This is used in callback function to potentially pay out the beneficiary.
    mapping(bytes32 => bytes32) public insuranceClaims;

    mapping(uint256 => AllowedInsurance) public allowedInsurances;


    uint256 public constant oracleBondPercentage = 0.001e18; // Proposal bond set to 0.1% of claimed insurance coverage.

    uint256 public constant optimisticOracleLivenessTime = 120; //3600 * 24; // Optimistic oracle liveness set to 24h.

    // Price identifier to use when requesting claims through Optimistic Oracle.
    bytes32 public constant priceIdentifier = "YES_OR_NO_QUERY";

    // Template for constructing ancillary data. The claim would insert insuredEvent in between when requesting
    // through Optimistic Oracle.
    string constant ancillaryDataHead = 'q:"Had the following protocol been hacked as of request timestamp: ';
    string constant ancillaryDataTail = '?"';

    FinderInterface public finder; // Finder for UMA contracts.

    OptimisticOracleV2Interface public immutable oo; // Optimistic Oracle instance where claims are resolved.

    IERC20 public immutable currency; // Denomination token for insurance coverage and bonding.

    //IIbAlluo public immutable alluo; // Alluo

    uint256 public constant MAX_EVENT_DESCRIPTION_SIZE = 300; // Insured event description should be concise.


    /****************************************
     *                EVENTS                *
     ****************************************/

    event PolicyIssued(
        bytes32 indexed policyId,
        address indexed insurer,
        string insuredEvent,
        address indexed insuredAddress,
        uint256 insuredAmount,
        uint256 premium
    );
    event PolicyCanceled(bytes32 indexed policyId, uint256 premium);

    event ClaimSubmitted(uint256 claimTimestamp, bytes32 indexed claimId, bytes32 indexed policyId);
    event ClaimAccepted(bytes32 indexed claimId, bytes32 indexed policyId);
    event ClaimRejected(bytes32 indexed claimId, bytes32 indexed policyId);

    /**
     * @notice Construct the InsuranceArbitrator
     * @param _finderAddress DVM finder to find other UMA ecosystem contracts.
     * @param _currency denomination token for insurance coverage and bonding.
     * @param _timer to enable simple time manipulation on this contract to simplify testing.
     * @param _alluoAddress _alluoAddress.
     */
    constructor(
        address _finderAddress,
        address _currency,
        address _timer,
        address _alluoAddress
    ) Testable(_timer) payable {
        finder = FinderInterface(_finderAddress);
        currency = IERC20(_currency);
        oo = OptimisticOracleV2Interface(finder.getImplementationAddress(OracleInterfaces.OptimisticOracleV2));
        //alluo = IIbAlluo(_alluoAddress);

    }

    /******************************************
     *          INSURANCE FUNCTIONS           *
     ******************************************/

    function calculateStake(uint256 _protocolAddress, uint256 _insuredAmount) public view returns(uint256){
        uint256 premium = allowedInsurances[_protocolAddress].premium;
        uint256 stake = premium * _insuredAmount / 1e18 / 1e6;
        return stake;
    }

    function issueInsurance(
        uint256 protocolAddress,
        string calldata insuredEvent,
        address insuredAddress,
        uint256 insuredAmount,
        uint256 premium
    ) external returns (bytes32 policyId) {
        require(bytes(insuredEvent).length <= MAX_EVENT_DESCRIPTION_SIZE, "Event description too long");
        require(insuredAddress != address(0), "Invalid insured address");
        require(insuredAmount > 0, "Amount should be above 0");
        require(premium >= calculateStake(protocolAddress, insuredAmount));
        //TODO: check if the protocol is in allowedInsurances
        policyId = _getPolicyId(block.number, insuredEvent, insuredAddress, insuredAmount);
        require(insurancePolicies[policyId].insuredAddress == address(0), "Policy already issued");

        InsurancePolicy storage newPolicy = insurancePolicies[policyId];
        newPolicy.insuredEvent = insuredEvent;
        newPolicy.insuredAddress = insuredAddress;
        newPolicy.insuredAmount = insuredAmount;
        newPolicy.premium = premium;

        userPolicies[insuredAddress].push(policyId);

        totalInsurancePremium += premium;

        // TODO: user has to approve in the frontend
        currency.safeTransferFrom(msg.sender, address(this), premium);

        //currency.approve(address(alluo), premium);
        //alluo.deposit(address(currency), premium);

        emit PolicyIssued(policyId, msg.sender, insuredEvent, insuredAddress, insuredAmount, premium);
    }

    /**
     * @notice Anyone can submit insurance claim posting oracle bonding. Only one simultaneous claim per insurance
     * policy is allowed.
     * @dev This contract must be approved to spend at least (insuredAmount * oracleBondPercentage + finalFee) of
     * currency token. This call requests and proposes that insuredEvent had ocured through Optimistic Oracle.
     * @param policyId Identifier of claimed insurance policy.
     */
    function submitClaim(bytes32 policyId) external {
        InsurancePolicy storage claimedPolicy = insurancePolicies[policyId];
        require(claimedPolicy.insuredAddress != address(0), "Insurance not issued");
        require(!claimedPolicy.claimInitiated, "Claim already initiated");

        claimedPolicy.claimInitiated = true;
        uint256 timestamp = getCurrentTime();
        bytes memory ancillaryData = abi.encodePacked(ancillaryDataHead, claimedPolicy.insuredEvent, ancillaryDataTail);
        bytes32 claimId = _getClaimId(timestamp, ancillaryData);
        insuranceClaims[claimId] = policyId;

        // Initiate price request at Optimistic Oracle.
        oo.requestPrice(priceIdentifier, timestamp, ancillaryData, currency, 0);

        // Configure price request parameters.
        uint256 proposerBond = (claimedPolicy.insuredAmount * oracleBondPercentage) / 1e18;
        uint256 totalBond = oo.setBond(priceIdentifier, timestamp, ancillaryData, proposerBond);
        oo.setCustomLiveness(priceIdentifier, timestamp, ancillaryData, optimisticOracleLivenessTime);
        oo.setCallbacks(priceIdentifier, timestamp, ancillaryData, false, false, true);

        // Propose canonical value representing "True"; i.e. the insurance claim is valid.
        currency.safeTransferFrom(msg.sender, address(this), totalBond);
        currency.safeApprove(address(oo), totalBond);
        oo.proposePriceFor(msg.sender, address(this), priceIdentifier, timestamp, ancillaryData, int256(1e18));

        emit ClaimSubmitted(timestamp, claimId, policyId);
    }

    function cancelInsurance(bytes32 policyId) external {
        InsurancePolicy storage insurancePolicy = insurancePolicies[policyId];

        require(msg.sender == insurancePolicy.insuredAddress, "Not the insurance owner");
        require(!insurancePolicy.claimInitiated, "Claim already initiated");

        // Withdraw from Alluo and transfer to the user
        //alluo.withdrawTo(insurancePolicy.insuredAddress, address(currency), insurancePolicy.premium);

        totalInsurancePremium -= insurancePolicy.premium;
        _deletePolicy(policyId);

        emit PolicyCanceled(policyId, insurancePolicy.premium);
    }

    function withdrawFromTreasury(uint256 amount) external onlyOwner {
        //alluo.withdrawTo(msg.sender, address(currency), amount);
    }

    function addAllowedInsurances(
        uint256 _protocolAddress,
        string memory _name,
        uint256 _premium //percentage 100000 = 1e5 = 0.1 = 10%
        )
        public
        onlyOwner
    {
        require(allowedInsurances[_protocolAddress].premium == 0, "Already exists");
        allowedInsurances[_protocolAddress] = AllowedInsurance({
            name: _name,
            premium: _premium
        });
    }

    /******************************************
     *           CALLBACK FUNCTIONS           *
     ******************************************/

    /**
     * @notice Callback function called by the Optimistic Oracle when the claim is settled. If the claim is confirmed
     * this pays out insurance coverage to the insured beneficiary and deletes the insurance policy. If the claim is
     * rejected policy claim state is reset so that it is ready for the subsequent claim attempts.
     * @param timestamp Timestamp of the price being requested.
     * @param ancillaryData Ancillary data of the price being requested.
     * @param price Price that was resolved by the escalation process.
     */
    function priceSettled(
        bytes32, // identifier passed by Optimistic Oracle, but not used here as it is always the same.
        uint256 timestamp,
        bytes memory ancillaryData,
        int256 price
    ) external {
        bytes32 claimId = _getClaimId(timestamp, ancillaryData);
        //require(address(oo) == msg.sender || owner() == msg.sender, "Unauthorized callback");

        // Claim can be settled only once, thus should be deleted.
        bytes32 policyId = insuranceClaims[claimId];
        InsurancePolicy memory claimedPolicy = insurancePolicies[policyId];
        delete insuranceClaims[claimId];

        // Deletes insurance policy and transfers claim amount if the claim was confirmed.
        if (price == 1e18) {
            currency.safeTransfer(claimedPolicy.insuredAddress, claimedPolicy.insuredAmount);
             _deletePolicy(policyId);

            emit ClaimAccepted(claimId, policyId);
            // Otherwise just reset the flag so that repeated claims can be made.
        } else {
            insurancePolicies[policyId].claimInitiated = false;

            emit ClaimRejected(claimId, policyId);
        }
    }

    /******************************************
     *           INTERNAL FUNCTIONS           *
     ******************************************/

    function _getPolicyId(
        uint256 blockNumber,
        string memory insuredEvent,
        address insuredAddress,
        uint256 insuredAmount
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(blockNumber, insuredEvent, insuredAddress, insuredAmount));
    }

    function _getClaimId(uint256 timestamp, bytes memory ancillaryData) public pure returns (bytes32) {
        return keccak256(abi.encode(timestamp, ancillaryData));
    }

    function _findArrayIndex(bytes32[] memory array, bytes32 value) internal pure returns(uint) {
        uint i = 0;
        while (array[i] != value) {
            i++;
        }
        return i;
    }

    function _deletePolicy(bytes32 policyId) internal{
        address insuredAddress = insurancePolicies[policyId].insuredAddress;
        uint index = _findArrayIndex(userPolicies[insuredAddress], policyId);
        delete userPolicies[insuredAddress][index];
        delete insurancePolicies[policyId];
    }

    receive() external payable {}
    fallback() external payable {}
    
}