// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @notice Advanced Track sibling of AIJudge.sol. Answers are encrypted
/// client-side to a per-bounty TEE executor public key and stored on-chain
/// only as ciphertext - there is no reveal phase, and no plaintext ever
/// touches the contract. See AIJudge.sol for the Required Track's
/// commit-reveal flow, which this contract intentionally does not modify or
/// depend on.
contract AIJudgeEncrypted is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_CIPHERTEXT_LENGTH = 4_000;

    uint256 public nextBountyId = 1;

    struct EncryptedSubmission {
        address submitter;
        bytes ciphertext; // sealed box: submitter -> teeExecutorPubKey
        bytes32 answerCommitment; // keccak256(plaintext), optional post-hoc audit
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 deadline; // single deadline: submission phase only
        bool judged;
        bool finalized;
        bytes teeExecutorPubKey;
        bytes aiReview;
        uint256 winnerIndex;
        EncryptedSubmission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => mapping(address => bool)) public hasSubmitted;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 deadline,
        bytes teeExecutorPubKey
    );

    event CiphertextSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline,
        bytes calldata teeExecutorPubKey
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(teeExecutorPubKey.length > 0, "tee pubkey required");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.deadline = deadline;
        bounty.teeExecutorPubKey = teeExecutorPubKey;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline, teeExecutorPubKey);
    }

    function submitCiphertext(
        uint256 bountyId,
        bytes calldata ciphertext,
        bytes32 answerCommitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(ciphertext.length > 0, "empty ciphertext");
        require(ciphertext.length <= MAX_CIPHERTEXT_LENGTH, "ciphertext too long");
        require(block.timestamp < bounty.deadline, "submission phase closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(!hasSubmitted[bountyId][msg.sender], "already submitted");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");

        hasSubmitted[bountyId][msg.sender] = true;
        bounty.submissions.push(
            EncryptedSubmission({
                submitter: msg.sender,
                ciphertext: ciphertext,
                answerCommitment: answerCommitment
            })
        );

        emit CiphertextSubmitted(bountyId, bounty.submissions.length - 1, msg.sender);
    }

    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.deadline, "submission phase not over");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length > 0, "no submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview,
            bytes memory teeExecutorPubKey
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.deadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview,
            bounty.teeExecutorPubKey
        );
    }

    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, bytes memory ciphertext, bytes32 answerCommitment)
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");
        EncryptedSubmission storage submission = bounty.submissions[index];
        return (submission.submitter, submission.ciphertext, submission.answerCommitment);
    }
}
