/**
 *        ███████████             ███
 *       ░░███░░░░░███           ░░░
 *        ░███    ░███  ██████   ████  ████████   ██████
 *        ░██████████  ░░░░░███ ░░███ ░░███░░███ ░░░░░███
 *        ░███░░░░░░    ███████  ░███  ░███ ░███  ███████
 *        ░███         ███░░███  ░███  ░███ ░███ ███░░███
 *        █████       ░░████████ █████ ░███████ ░░████████
 *       ░░░░░         ░░░░░░░░ ░░░░░  ░███░░░   ░░░░░░░░
 *                                     ░███
 *                                     █████
 *                                    ░░░░░
 */

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/console.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {BitMaps} from "openzeppelin-contracts/contracts/utils/structs/BitMaps.sol";
import {Helpers} from "./libraries/Helpers.sol";
import {IBundler} from "./interfaces/IBundler.sol";

// TODO: how reentrancy can affect execution

// TODO: how to work with ERC721 and ERC1155 approvals
// @dev this contract doesn't support ERC1155 transactions nor payable transactions
// TODO: maybe convert the contract to support multiple bundlers(?)
contract Bundler is IBundler, AccessControl, Pausable {
    using BitMaps for BitMaps.BitMap;
    using SafeERC20 for IERC20;

    bytes32 private constant BUNDLE_RUNNER = keccak256("BUNDLE_RUNNER");

    // TODO: how to use only Bitmaps for this
    // @dev Transaction ID => BitMap
    mapping(uint256 => BitMaps.BitMap) private argsBitmap;

    Transaction[] private transactions;
    uint256 private lastExecutionTimestamp;
    uint256 private executionInterval;
    uint256 private runs;

    error TransactionError(uint256 transactionId, bytes result);
    error InvalidTarget();
    error ExecutionBeforeInterval();
    error ArgsMismatch();
    error NotAllowedToRunBundle();
    error FirstTransactionWithDynamicArg(uint256 argIndex);

    constructor(address _owner, uint256 _executionInterval) {
        executionInterval = _executionInterval;
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    }

    // TODO: first transaction of the bundle cannot be dynamic
    // TODO: add max transacion per bundle
    // TODO: how to make users pay for the gas usage (?)
    function createBundle(Transaction[] memory _transactions, bool[][] calldata _argTypes)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_argTypes.length != _transactions.length) {
            console.log('Args mismatch');

            revert ArgsMismatch();
        }

        // @dev In order to override the current transactions
        if (transactions.length > 0) {
            // TODO: calling delete on a dynamic array in storage sets the array
            // lenght to zero, but doesn't free the slots used by the array items
            // so this is maybe a problem
            // UNFOLD: as the array size is set to zero, we cannot access the element
            // using the array index, it throws an index out of bounds.
            // Although that might be safe enough, should test the scenarios where this
            // can be exploited by using inline assembly
            delete transactions;
        }

        for (uint256 i = 0; i < _transactions.length; i++) {
            Transaction memory transaction = _transactions[i];
            bool[] memory argType = _argTypes[i];

            if (argType.length != transaction.args.length) {
                console.log('Args mismatch 2');

                revert ArgsMismatch();
            }

            if (transaction.target == address(0)) {
                console.log('Invalid targ');
                revert InvalidTarget();
            }

            for (uint256 j = 0; j < transaction.args.length; j++) {
                // @dev The first transaction canno receive dynamic arguments
                if (i == 0 && argType[j] == true) {
                    console.log('FirstTransactionWithDynamicArg');

                    revert FirstTransactionWithDynamicArg(j);
                }

                argsBitmap[i].setTo(j, argType[j]);
            }

            transactions.push(transaction);
        }
    }

    function getBundle() external view returns (Transaction[] memory) {
        return transactions;
    }

    function argTypeIsDynamic(uint256 transactionId, uint256 argId) external view returns (bool) {
        return argsBitmap[transactionId].get(argId);
    }

    // TODO: time guard
    function runBundle() external whenNotPaused {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(BUNDLE_RUNNER, msg.sender)) {
            revert NotAllowedToRunBundle();
        }

        bytes memory lastTransactionResult;

        for (uint8 i; i < transactions.length; i++) {
            Transaction memory transaction = transactions[i];
            bytes memory data = buildData(i, transaction, lastTransactionResult);

            (bool success, bytes memory result) = transaction.target.call(data);

            if (!success) {
                revert TransactionError(i, result);
            }

            lastTransactionResult = result;
        }

        runs += 1;
    }

    function buildData(uint256 _transactionId, Transaction memory _transaction, bytes memory _lastTransactionResult)
        internal
        view
        returns (bytes memory data)
    {
        data = abi.encodeWithSignature(_transaction.functionSignature);

        for (uint8 i; i < _transaction.args.length; i++) {
            // @dev is dynamic arg
            if (argsBitmap[_transactionId].get(i)) {
                uint256 interval = Helpers.bytesToUint256(_transaction.args[i]);

                data = bytes.concat(data, Helpers.getSlice(_lastTransactionResult, interval));
            } else {
                data = bytes.concat(data, _transaction.args[i]);
            }
        }
    }

    // TODO: this function get the amount
    function pullFee() internal {}

    // TODO: add event
    // @notice Execute an arbitrary transaction in order for this contract to become
    // the owner of a given position in a given contract
    function runTransaction(address target, bytes calldata data)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes memory)
    {
        if (target == address(this)) {
            revert InvalidTarget();
        }

        (bool success, bytes memory result) = target.call(data);

        if (!success) {
            revert TransactionError(0, result);
        }

        return result;
    }

    // TODO: add event
    function setExecutionInterval(uint256 _executionInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        executionInterval = _executionInterval;
    }

    function withdrawERC20(address _token, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function withdraw721(address _token, uint256 _tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC721(_token).safeTransferFrom(address(this), msg.sender, _tokenId);
    }

    function getRuns() external view returns (uint256) {
        return runs;
    }

    function getTransactions() external view returns (Transaction[] memory) {
        return transactions;
    }

    function approveRunner(address _runner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(BUNDLE_RUNNER, _runner);
    }

    function revokeRunner(address _runner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(BUNDLE_RUNNER, _runner);
    }
}