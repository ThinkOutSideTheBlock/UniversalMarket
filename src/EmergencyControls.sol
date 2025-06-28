// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EmergencyControls is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    struct ScheduledTransaction {
        address target;
        bytes data;
        uint256 executeTime;
        bool executed;
        bool cancelled;
    }

    struct EmergencyAction {
        uint256 timestamp;
        uint256 confirmations;
        bool executed;
        mapping(address => bool) hasConfirmed;
    }

    mapping(bytes32 => ScheduledTransaction) public scheduledTx;
    mapping(address => bool) public contractPaused;
    mapping(bytes32 => EmergencyAction) public emergencyActions;

    uint256 public constant TIME_LOCK = 24 hours;
    uint256 public constant EMERGENCY_TIMELOCK = 6 hours;
    uint256 public constant MIN_CONFIRMATIONS = 2;

    address[] public guardians;

    event TransactionScheduled(
        bytes32 indexed txHash,
        address target,
        uint256 executeTime
    );
    event TransactionExecuted(bytes32 indexed txHash);
    event TransactionCancelled(bytes32 indexed txHash);
    event ContractPaused(address indexed contractAddr);
    event ContractUnpaused(address indexed contractAddr);
    event EmergencyPause();
    event EmergencyActionProposed(bytes32 indexed actionId, address proposer);
    event EmergencyActionConfirmed(bytes32 indexed actionId, address guardian);
    event EmergencyActionExecuted(bytes32 indexed actionId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        guardians.push(msg.sender);
    }

    modifier onlyMultiSig(bytes32 actionId) {
        require(
            emergencyActions[actionId].timestamp > 0,
            "Action not proposed"
        );
        require(
            block.timestamp >=
                emergencyActions[actionId].timestamp + EMERGENCY_TIMELOCK,
            "Timelock not expired"
        );
        require(
            emergencyActions[actionId].confirmations >= MIN_CONFIRMATIONS,
            "Insufficient confirmations"
        );
        require(!emergencyActions[actionId].executed, "Already executed");
        _;
        emergencyActions[actionId].executed = true;
    }

    modifier whenContractNotPaused(address contractAddr) {
        require(!paused() && !contractPaused[contractAddr], "Contract paused");
        _;
    }

    function addGuardian(
        address guardian
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(guardian != address(0), "Invalid guardian");
        require(!hasRole(GUARDIAN_ROLE, guardian), "Already guardian");

        grantRole(GUARDIAN_ROLE, guardian);
        guardians.push(guardian);
    }

    function removeGuardian(
        address guardian
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(guardians.length > MIN_CONFIRMATIONS, "Too few guardians");

        revokeRole(GUARDIAN_ROLE, guardian);

        // Remove from array
        for (uint i = 0; i < guardians.length; i++) {
            if (guardians[i] == guardian) {
                guardians[i] = guardians[guardians.length - 1];
                guardians.pop();
                break;
            }
        }
    }

    function proposeEmergencyAction(
        string memory actionType
    ) external onlyRole(GUARDIAN_ROLE) returns (bytes32) {
        bytes32 actionId = keccak256(
            abi.encodePacked(actionType, block.timestamp, msg.sender)
        );

        EmergencyAction storage action = emergencyActions[actionId];
        action.timestamp = block.timestamp;
        action.confirmations = 1;
        action.hasConfirmed[msg.sender] = true;

        emit EmergencyActionProposed(actionId, msg.sender);
        return actionId;
    }

    function confirmEmergencyAction(
        bytes32 actionId
    ) external onlyRole(GUARDIAN_ROLE) {
        EmergencyAction storage action = emergencyActions[actionId];
        require(action.timestamp > 0, "Action not proposed");
        require(!action.hasConfirmed[msg.sender], "Already confirmed");
        require(!action.executed, "Already executed");

        action.hasConfirmed[msg.sender] = true;
        action.confirmations++;

        emit EmergencyActionConfirmed(actionId, msg.sender);
    }

    function pauseContract(
        address contractAddr
    ) external onlyRole(GUARDIAN_ROLE) {
        contractPaused[contractAddr] = true;
        emit ContractPaused(contractAddr);
    }

    function unpauseContract(
        address contractAddr
    ) external onlyRole(GUARDIAN_ROLE) {
        contractPaused[contractAddr] = false;
        emit ContractUnpaused(contractAddr);
    }

    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit EmergencyPause();
    }

    function emergencyUnpause(
        bytes32 actionId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) onlyMultiSig(actionId) {
        _unpause();
        emit EmergencyActionExecuted(actionId);
    }

    function scheduleTransaction(
        address target,
        bytes calldata data
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes32) {
        bytes32 txHash = keccak256(abi.encode(target, data, block.timestamp));

        scheduledTx[txHash] = ScheduledTransaction({
            target: target,
            data: data,
            executeTime: block.timestamp + TIME_LOCK,
            executed: false,
            cancelled: false
        });

        emit TransactionScheduled(txHash, target, block.timestamp + TIME_LOCK);
        return txHash;
    }

    function cancelScheduledTransaction(
        bytes32 txHash
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ScheduledTransaction storage transaction = scheduledTx[txHash];
        require(transaction.executeTime != 0, "Transaction not scheduled");
        require(!transaction.executed, "Transaction already executed");
        require(!transaction.cancelled, "Transaction already cancelled");

        transaction.cancelled = true;
        emit TransactionCancelled(txHash);
    }

    function executeScheduledTransaction(
        bytes32 txHash
    ) external onlyRole(EXECUTOR_ROLE) {
        ScheduledTransaction storage transaction = scheduledTx[txHash];
        require(transaction.executeTime != 0, "Transaction not scheduled");
        require(
            block.timestamp >= transaction.executeTime,
            "Time lock not expired"
        );
        require(!transaction.executed, "Transaction already executed");
        require(!transaction.cancelled, "Transaction cancelled");

        transaction.executed = true;

        (bool success, bytes memory returnData) = transaction.target.call(
            transaction.data
        );
        if (!success) {
            // If the call failed, bubble up the revert reason
            if (returnData.length > 0) {
                assembly {
                    let returndata_size := mload(returnData)
                    revert(add(32, returnData), returndata_size)
                }
            } else {
                revert("Transaction execution failed");
            }
        }

        emit TransactionExecuted(txHash);
    }

    function emergencyWithdraw(
        bytes32 actionId,
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) onlyMultiSig(actionId) {
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH");
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).transfer(msg.sender, amount);
        }
        emit EmergencyActionExecuted(actionId);
    }

    function isContractPaused(
        address contractAddr
    ) external view returns (bool) {
        return paused() || contractPaused[contractAddr];
    }

    function getGuardians() external view returns (address[] memory) {
        return guardians;
    }

    function getActionInfo(
        bytes32 actionId
    )
        external
        view
        returns (uint256 timestamp, uint256 confirmations, bool executed)
    {
        EmergencyAction storage action = emergencyActions[actionId];
        return (action.timestamp, action.confirmations, action.executed);
    }
}
