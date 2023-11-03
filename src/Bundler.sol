/**
       ███████████             ███                     
      ░░███░░░░░███           ░░░                      
       ░███    ░███  ██████   ████  ████████   ██████  
       ░██████████  ░░░░░███ ░░███ ░░███░░███ ░░░░░███ 
       ░███░░░░░░    ███████  ░███  ░███ ░███  ███████ 
       ░███         ███░░███  ░███  ░███ ░███ ███░░███ 
       █████       ░░████████ █████ ░███████ ░░████████
      ░░░░░         ░░░░░░░░ ░░░░░  ░███░░░   ░░░░░░░░ 
                                    ░███               
                                    █████              
                                   ░░░░░         
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/console.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {BitMaps} from "openzeppelin-contracts/contracts/utils/structs/BitMaps.sol";
import {PaipaLibrary} from "./PaipaLibrary.sol";

// TODO: how reentrancy can affect execution

// TODO: how to work with ERC721 and ERC1155 approvals
// @dev this contract doesn't support ERC1155 transactions nor payable transactions
// TODO: maybe convert the contract to support multiple bundlers(?)
contract Bundler is Ownable, Pausable {
    using BitMaps for BitMaps.BitMap;
    using SafeERC20 for IERC20;

    struct Transaction {
        address target;
        string functionSignature;
        bytes[] args;
    }

    // TODO: how to use only Bitmaps for this
    // @dev Transaction ID => BitMap
    mapping(uint256 => BitMaps.BitMap) private argsBitmap;

    Transaction[] private transactions;
    uint256 private lastExecutionTimestamp;
    uint256 private executionInterval;

    error TransactionError(uint256 transactionId, bytes result); 
    error InvalidTarget();
    error ExecutionBeforeInterval();
    error ArgsMismatch();

    constructor(address _owner, uint256 _executionInterval) Ownable(_owner) {
        executionInterval = _executionInterval;
    }

    function createBundle(
        Transaction[] memory _transactions,
        bool[][] calldata _argTypes
    ) external onlyOwner {
        // TODO: does really costs less gas?
        Transaction[] storage transactionsRef = transactions;

        if (_argTypes.length != _transactions.length)
            revert ArgsMismatch();

        // @dev In order to override the current transactions
        if (transactionsRef.length > 0)
            // TODO: calling delete on a dynamic array in storage sets the array
            // lenght to zero, but doesn't free the slots used by the array items
            // so this is maybe a problem
            // UNFOLD: as the array size is set to zero, we cannot access the element
            // using the array index, it throws an index out of bounds.
            // Although that might be safe enough, should test the scenarios where this 
            // can be exploited by using inline assembly
            delete transactions;

        for (uint256 i = 0; i < _transactions.length; i++) {
            Transaction memory transaction = _transactions[i];
            bool[] memory argType = _argTypes[i];

            if (argType.length != transaction.args.length) {
                console.log('Arg type length: %s | Transactions args length: %s', argType.length, transaction.args.length);
                console.log('Reverts on for loop | index: ', i);

                revert ArgsMismatch();
            }

            if (transaction.target == address(0))
                revert InvalidTarget();

            for (uint j = 0; j < transaction.args.length; j++) {
                argsBitmap[i].setTo(j, argType[j]);
            }

            transactionsRef.push(transaction);
        }
    }

    function getBundle() external view returns (Transaction[] memory) {
        return transactions;
    }

    function argTypeIsDynamic(uint transactionId, uint argId) external view returns (bool) {
        return argsBitmap[transactionId].get(argId);
    }

    // TODO: time guard
    function runBundle() external onlyOwner whenNotPaused {
        bytes memory lastTransactionResult;

        for (uint8 i; i < transactions.length; i++)  {
            console.log('Running tx: ', i);

            Transaction memory transaction = transactions[i];
            bytes memory data = buildData(i, transaction, lastTransactionResult);

            console.logBytes(data);

            (bool success, bytes memory result) = transaction.target.call(data);

            if (!success)
                revert TransactionError(i, result);

            lastTransactionResult = result;
        }
    }

    function buildData(
        uint _transactionId,
        Transaction memory _transaction,
        bytes memory _lastTransactionResult
    ) internal view returns (bytes memory data) {
        data = abi.encodeWithSignature(_transaction.functionSignature);

        for (uint8 i; i < _transaction.args.length; i++) {
            // @dev is dynamic arg
            if (argsBitmap[_transactionId].get(i)) {
                uint256 interval = PaipaLibrary.bytesToUint256(_transaction.args[i]);

                data = bytes.concat(data, PaipaLibrary.getSlice(_lastTransactionResult, interval));
            } else {
               data = bytes.concat(data, _transaction.args[i]);
            }
        }
    }

    // TODO: this function get the amount 
    function pullFee() internal {}

    // @notice Execute an arbitrary transaction in order for this contract to become
    // the owner of a given position in a given contract
    function runTransaction(address target, bytes calldata data) external onlyOwner returns (bytes memory) {
        if (target == address(this))
            revert InvalidTarget();

        (bool success, bytes memory result) = target.call(data);

        if (!success)
            revert TransactionError(0, result);

        return result;
    }

 
    function setExecutionInterval(uint256 _executionInterval) external onlyOwner {
        executionInterval = _executionInterval;
    }

    function withdrawERC20(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(owner(), _amount);
    }

    function withdraw721(address _token, uint256 _tokenId) public onlyOwner {
        IERC721(_token).safeTransferFrom(address(this), owner(), _tokenId);
    }
}
