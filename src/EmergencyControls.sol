// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IControllable {
    function pause() external;
    function unpause() external;
    function emergencyWithdraw() external;
}

contract EmergencyControls is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    struct ScheduledTransaction {
        address target;
        bytes data;
        uint256 executeTime;
        bool executed;
        bool cancelled;
        string description;
    }

    struct EmergencyAction {
        uint256 timestamp;
        uint256 confirmations;
        bool executed;
        string actionType;
        address target;
        bytes data;
        mapping(address => bool) hasConfirmed;
    }

    // System contracts
    mapping(address => bool) public systemContracts;
    mapping(address => bool) public contractPaused;
    address[] public registeredContracts;

    // Emergency actions
    mapping(bytes32 => ScheduledTransaction) public scheduledTx;
    mapping(bytes32 => EmergencyAction) public emergencyActions;

    // Timelock settings
    uint256 public constant TIME_LOCK = 24 hours;
    uint256 public constant EMERGENCY_TIMELOCK = 6 hours;
    uint256 public constant MIN_CONFIRMATIONS = 2;
    uint256 public constant MAX_GUARDIANS = 10;

    address[] public guardians;
    uint256 public emergencyActionsCount;
    bool public systemWideEmergency;

    // Events
    event SystemContractRegistered(
        address indexed contractAddr,
        bool registered
    );
    event TransactionScheduled(
        bytes32 indexed txHash,
        address target,
        uint256 executeTime,
        string description
    );
    event TransactionExecuted(bytes32 indexed txHash);
    event TransactionCancelled(bytes32 indexed txHash);
    event ContractPaused(address indexed contractAddr);
    event ContractUnpaused(address indexed contractAddr);
    event SystemWideEmergencyActivated(address indexed activator);
    event SystemWideEmergencyDeactivated(address indexed deactivator);
    event EmergencyActionProposed(
        bytes32 indexed actionId,
        address proposer,
        string actionType
    );
    event EmergencyActionConfirmed(bytes32 indexed actionId, address guardian);
    event EmergencyActionExecuted(bytes32 indexed actionId);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        guardians.push(msg.sender);
    }

    modifier onlyMultiSig(bytes32 actionId) {
        EmergencyAction storage action = emergencyActions[actionId];
        require(action.timestamp > 0, "Action not proposed");
        require(
            block.timestamp >= action.timestamp + EMERGENCY_TIMELOCK,
            "Timelock not expired"
        );
        require(
            action.confirmations >= MIN_CONFIRMATIONS,
            "Insufficient confirmations"
        );
        require(!action.executed, "Already executed");
        _;
        action.executed = true;
    }

    modifier whenSystemNotPaused() {
        require(!paused() && !systemWideEmergency, "System emergency active");
        _;
    }

    modifier validContract(address contractAddr) {
        require(contractAddr != address(0), "Invalid contract address");
        require(contractAddr.code.length > 0, "Not a contract");
        _;
    }

    // ============ SYSTEM CONTRACT REGISTRATION ============

    function registerSystemContract(
        address contractAddr,
        bool isSystemContract
    ) external onlyRole(DEFAULT_ADMIN_ROLE) validContract(contractAddr) {
        if (isSystemContract && !systemContracts[contractAddr]) {
            systemContracts[contractAddr] = true;
            registeredContracts.push(contractAddr);
        } else if (!isSystemContract && systemContracts[contractAddr]) {
            systemContracts[contractAddr] = false;
            // Remove from array
            for (uint i = 0; i < registeredContracts.length; i++) {
                if (registeredContracts[i] == contractAddr) {
                    registeredContracts[i] = registeredContracts[
                        registeredContracts.length - 1
                    ];
                    registeredContracts.pop();
                    break;
                }
            }
        }

        emit SystemContractRegistered(contractAddr, isSystemContract);
    }

    function batchRegisterContracts(
        address[] calldata contracts,
        bool[] calldata statuses
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(contracts.length == statuses.length, "Array length mismatch");
        require(contracts.length <= 20, "Too many contracts");

        for (uint i = 0; i < contracts.length; i++) {
            if (contracts[i] != address(0) && contracts[i].code.length > 0) {
                if (statuses[i] && !systemContracts[contracts[i]]) {
                    systemContracts[contracts[i]] = true;
                    registeredContracts.push(contracts[i]);
                } else if (!statuses[i] && systemContracts[contracts[i]]) {
                    systemContracts[contracts[i]] = false;
                    // Remove from array
                    for (uint j = 0; j < registeredContracts.length; j++) {
                        if (registeredContracts[j] == contracts[i]) {
                            registeredContracts[j] = registeredContracts[
                                registeredContracts.length - 1
                            ];
                            registeredContracts.pop();
                            break;
                        }
                    }
                }
                emit SystemContractRegistered(contracts[i], statuses[i]);
            }
        }
    }

    // ============ GUARDIAN MANAGEMENT ============

    function addGuardian(
        address guardian
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(guardian != address(0), "Invalid guardian");
        require(!hasRole(GUARDIAN_ROLE, guardian), "Already guardian");
        require(guardians.length < MAX_GUARDIANS, "Too many guardians");

        grantRole(GUARDIAN_ROLE, guardian);
        guardians.push(guardian);
        emit GuardianAdded(guardian);
    }

    function removeGuardian(
        address guardian
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(guardians.length > MIN_CONFIRMATIONS, "Too few guardians");
        require(hasRole(GUARDIAN_ROLE, guardian), "Not a guardian");

        revokeRole(GUARDIAN_ROLE, guardian);

        // Remove from array
        for (uint i = 0; i < guardians.length; i++) {
            if (guardians[i] == guardian) {
                guardians[i] = guardians[guardians.length - 1];
                guardians.pop();
                break;
            }
        }

        emit GuardianRemoved(guardian);
    }

    // ============ EMERGENCY ACTIONS ============

    function proposeEmergencyAction(
        string memory actionType,
        address target,
        bytes memory data
    ) external onlyRole(GUARDIAN_ROLE) returns (bytes32) {
        bytes32 actionId = keccak256(
            abi.encodePacked(
                actionType,
                target,
                data,
                block.timestamp,
                msg.sender
            )
        );

        EmergencyAction storage action = emergencyActions[actionId];
        action.timestamp = block.timestamp;
        action.confirmations = 1;
        action.actionType = actionType;
        action.target = target;
        action.data = data;
        action.hasConfirmed[msg.sender] = true;

        emergencyActionsCount++;
        emit EmergencyActionProposed(actionId, msg.sender, actionType);
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

    function executeEmergencyAction(
        bytes32 actionId
    ) external onlyRole(GUARDIAN_ROLE) onlyMultiSig(actionId) nonReentrant {
        EmergencyAction storage action = emergencyActions[actionId];

        if (action.target != address(0) && action.data.length > 0) {
            (bool success, bytes memory returnData) = action.target.call(
                action.data
            );
            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        let returndata_size := mload(returnData)
                        revert(add(32, returnData), returndata_size)
                    }
                } else {
                    revert("Emergency action execution failed");
                }
            }
        }

        emit EmergencyActionExecuted(actionId);
    }

    // ============ INDIVIDUAL CONTRACT CONTROLS ============

    function pauseContract(
        address contractAddr
    ) external onlyRole(GUARDIAN_ROLE) validContract(contractAddr) {
        require(systemContracts[contractAddr], "Contract not registered");
        contractPaused[contractAddr] = true;

        // Try to pause the contract directly
        try IControllable(contractAddr).pause() {
            // Success
        } catch {
            // Contract doesn't support direct pausing, only track in mapping
        }

        emit ContractPaused(contractAddr);
    }

    function unpauseContract(
        address contractAddr
    ) external onlyRole(GUARDIAN_ROLE) validContract(contractAddr) {
        require(systemContracts[contractAddr], "Contract not registered");
        contractPaused[contractAddr] = false;

        // Try to unpause the contract directly
        try IControllable(contractAddr).unpause() {
            // Success
        } catch {
            // Contract doesn't support direct unpausing, only track in mapping
        }

        emit ContractUnpaused(contractAddr);
    }

    function batchPauseContracts(
        address[] calldata contracts
    ) external onlyRole(GUARDIAN_ROLE) {
        require(contracts.length <= 20, "Too many contracts");

        for (uint i = 0; i < contracts.length; i++) {
            address contractAddr = contracts[i];
            if (
                systemContracts[contractAddr] && !contractPaused[contractAddr]
            ) {
                contractPaused[contractAddr] = true;

                try IControllable(contractAddr).pause() {
                    // Success
                } catch {
                    // Contract doesn't support direct pausing
                }

                emit ContractPaused(contractAddr);
            }
        }
    }

    function batchUnpauseContracts(
        address[] calldata contracts
    ) external onlyRole(GUARDIAN_ROLE) {
        require(contracts.length <= 20, "Too many contracts");

        for (uint i = 0; i < contracts.length; i++) {
            address contractAddr = contracts[i];
            if (systemContracts[contractAddr] && contractPaused[contractAddr]) {
                contractPaused[contractAddr] = false;

                try IControllable(contractAddr).unpause() {
                    // Success
                } catch {
                    // Contract doesn't support direct unpausing
                }

                emit ContractUnpaused(contractAddr);
            }
        }
    }

    // ============ SYSTEM-WIDE EMERGENCY ============

    function activateSystemWideEmergency() external onlyRole(EMERGENCY_ROLE) {
        systemWideEmergency = true;
        _pause();

        // Pause all registered contracts
        for (uint i = 0; i < registeredContracts.length; i++) {
            address contractAddr = registeredContracts[i];
            if (!contractPaused[contractAddr]) {
                contractPaused[contractAddr] = true;
                try IControllable(contractAddr).pause() {
                    // Success
                } catch {
                    // Contract doesn't support direct pausing
                }
                emit ContractPaused(contractAddr);
            }
        }

        emit SystemWideEmergencyActivated(msg.sender);
    }

    function deactivateSystemWideEmergency(
        bytes32 actionId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) onlyMultiSig(actionId) {
        systemWideEmergency = false;
        _unpause();

        emit SystemWideEmergencyDeactivated(msg.sender);
    }

    // ============ TIMELOCK FUNCTIONS ============

    function scheduleTransaction(
        address target,
        bytes calldata data,
        string calldata description
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes32) {
        bytes32 txHash = keccak256(
            abi.encode(target, data, block.timestamp, description)
        );

        scheduledTx[txHash] = ScheduledTransaction({
            target: target,
            data: data,
            executeTime: block.timestamp + TIME_LOCK,
            executed: false,
            cancelled: false,
            description: description
        });

        emit TransactionScheduled(
            txHash,
            target,
            block.timestamp + TIME_LOCK,
            description
        );
        return txHash;
    }

    function batchScheduleTransactions(
        address[] calldata targets,
        bytes[] calldata dataArray,
        string[] calldata descriptions
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes32[] memory) {
        require(
            targets.length == dataArray.length &&
                dataArray.length == descriptions.length,
            "Array length mismatch"
        );
        require(targets.length <= 10, "Too many transactions");

        bytes32[] memory txHashes = new bytes32[](targets.length);

        for (uint i = 0; i < targets.length; i++) {
            bytes32 txHash = keccak256(
                abi.encode(
                    targets[i],
                    dataArray[i],
                    block.timestamp,
                    descriptions[i]
                )
            );

            scheduledTx[txHash] = ScheduledTransaction({
                target: targets[i],
                data: dataArray[i],
                executeTime: block.timestamp + TIME_LOCK,
                executed: false,
                cancelled: false,
                description: descriptions[i]
            });

            txHashes[i] = txHash;
            emit TransactionScheduled(
                txHash,
                targets[i],
                block.timestamp + TIME_LOCK,
                descriptions[i]
            );
        }

        return txHashes;
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
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
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

    // ============ EMERGENCY WITHDRAWAL ============

    function emergencyWithdrawETH(
        bytes32 actionId,
        uint256 amount
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyMultiSig(actionId)
        nonReentrant
    {
        require(amount <= address(this).balance, "Insufficient ETH");
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit EmergencyActionExecuted(actionId);
    }

    function emergencyWithdrawToken(
        bytes32 actionId,
        address token,
        uint256 amount
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyMultiSig(actionId)
        nonReentrant
    {
        IERC20(token).transfer(msg.sender, amount);
        emit EmergencyActionExecuted(actionId);
    }

    function batchEmergencyWithdraw(
        bytes32 actionId
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyMultiSig(actionId)
        nonReentrant
    {
        // Trigger emergency withdraw on all registered contracts
        for (uint i = 0; i < registeredContracts.length; i++) {
            try IControllable(registeredContracts[i]).emergencyWithdraw() {
                // Success
            } catch {
                // Contract doesn't support emergency withdraw or failed
            }
        }

        emit EmergencyActionExecuted(actionId);
    }

    // ============ VIEW FUNCTIONS ============

    function isContractPaused(
        address contractAddr
    ) external view returns (bool) {
        return paused() || systemWideEmergency || contractPaused[contractAddr];
    }

    function getGuardians() external view returns (address[] memory) {
        return guardians;
    }

    function getRegisteredContracts() external view returns (address[] memory) {
        return registeredContracts;
    }

    function getActionInfo(
        bytes32 actionId
    )
        external
        view
        returns (
            uint256 timestamp,
            uint256 confirmations,
            bool executed,
            string memory actionType,
            address target
        )
    {
        EmergencyAction storage action = emergencyActions[actionId];
        return (
            action.timestamp,
            action.confirmations,
            action.executed,
            action.actionType,
            action.target
        );
    }

    function getScheduledTransactionInfo(
        bytes32 txHash
    )
        external
        view
        returns (
            address target,
            uint256 executeTime,
            bool executed,
            bool cancelled,
            string memory description
        )
    {
        ScheduledTransaction storage scheduledTransaction = scheduledTx[txHash]; // FIXED: renamed from 'tx'
        return (
            scheduledTransaction.target,
            scheduledTransaction.executeTime,
            scheduledTransaction.executed,
            scheduledTransaction.cancelled,
            scheduledTransaction.description
        );
    }

    function hasConfirmedAction(
        bytes32 actionId,
        address guardian
    ) external view returns (bool) {
        return emergencyActions[actionId].hasConfirmed[guardian];
    }

    function getSystemStatus()
        external
        view
        returns (
            bool _paused,
            bool _systemWideEmergency,
            uint256 _registeredContractsCount,
            uint256 _guardiansCount,
            uint256 _emergencyActionsCount
        )
    {
        return (
            paused(),
            systemWideEmergency,
            registeredContracts.length,
            guardians.length,
            emergencyActionsCount
        );
    }

    // ============ ADMIN FUNCTIONS ============

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    receive() external payable {
        // Allow contract to receive ETH for emergency situations
    }
}
