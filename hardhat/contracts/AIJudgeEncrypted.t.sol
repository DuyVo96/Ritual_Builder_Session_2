// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudgeEncrypted} from "./AIJudgeEncrypted.sol";

/// @notice Guard/state tests for the Advanced Track contract.
/// Mirrors AIJudge.t.sol's coverage where the lifecycle overlaps
/// (createBounty guards, submission guards, judgeAll pre-precompile guards,
/// finalizeWinner). There is no reveal phase here, so reveal-specific tests
/// from AIJudge.t.sol have no equivalent.
///
/// As in AIJudge.t.sol, judgeAll's real precompile output is never mocked
/// anywhere in this repo - test_JudgeAllBeforeDeadlineReverts only exercises
/// the timestamp guard before the precompile is ever reached. Real TEE
/// decryption behavior cannot be verified locally; see SUBMISSION.md.
contract AIJudgeEncryptedTest is Test {
    AIJudgeEncrypted judge;

    address owner = address(1);
    address alice = address(2);
    address bob   = address(3);

    uint256 submissionDeadline;
    uint256 bountyId;
    bytes teeExecutorPubKey = hex"deadbeef";

    function setUp() public {
        judge = new AIJudgeEncrypted();
        submissionDeadline = block.timestamp + 1 hours;

        vm.deal(owner, 10 ether);
        vm.prank(owner);
        bountyId = judge.createBounty{value: 1 ether}(
            "Test bounty",
            "rubric: be correct",
            submissionDeadline,
            teeExecutorPubKey
        );
    }

    // ---- happy path ----

    function test_SubmitCiphertextStoresCiphertextNotPlaintext() public {
        string memory plaintextAnswer = "My secret answer";
        bytes memory ciphertext = bytes("not-the-plaintext-obviously-encrypted-blob");
        bytes32 commitment = keccak256(bytes(plaintextAnswer));

        vm.prank(alice);
        judge.submitCiphertext(bountyId, ciphertext, commitment);

        (address submitter, bytes memory storedCiphertext, bytes32 storedCommitment) =
            judge.getSubmission(bountyId, 0);

        assertEq(submitter, alice);
        assertEq(storedCommitment, commitment);
        assertTrue(
            keccak256(storedCiphertext) != keccak256(bytes(plaintextAnswer)),
            "ciphertext must never equal plaintext"
        );
    }

    function test_SubmissionCountIncrements() public {
        vm.prank(alice);
        judge.submitCiphertext(bountyId, bytes("cipher-a"), bytes32("commit-a"));

        vm.prank(bob);
        judge.submitCiphertext(bountyId, bytes("cipher-b"), bytes32("commit-b"));

        (, , , , , , , uint256 submissionCount, , , ) = judge.getBounty(bountyId);
        assertEq(submissionCount, 2);
    }

    // ---- submission phase guards ----

    function test_SubmitAfterDeadlineReverts() public {
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        vm.expectRevert("submission phase closed");
        judge.submitCiphertext(bountyId, bytes("cipher"), bytes32("commit"));
    }

    function test_DoubleSubmitCiphertextReverts() public {
        vm.prank(alice);
        judge.submitCiphertext(bountyId, bytes("cipher"), bytes32("commit"));

        vm.prank(alice);
        vm.expectRevert("already submitted");
        judge.submitCiphertext(bountyId, bytes("cipher-2"), bytes32("commit-2"));
    }

    function test_EmptyCiphertextReverts() public {
        vm.prank(alice);
        vm.expectRevert("empty ciphertext");
        judge.submitCiphertext(bountyId, bytes(""), bytes32("commit"));
    }

    function test_CiphertextTooLongReverts() public {
        bytes memory tooLong = new bytes(judge.MAX_CIPHERTEXT_LENGTH() + 1);
        vm.prank(alice);
        vm.expectRevert("ciphertext too long");
        judge.submitCiphertext(bountyId, tooLong, bytes32("commit"));
    }

    function test_TooManySubmissionsReverts() public {
        uint256 max = judge.MAX_SUBMISSIONS();
        for (uint256 i = 0; i < max; i++) {
            address participant = address(uint160(100 + i));
            vm.prank(participant);
            judge.submitCiphertext(bountyId, bytes("cipher"), bytes32("commit"));
        }

        vm.prank(address(999));
        vm.expectRevert("too many submissions");
        judge.submitCiphertext(bountyId, bytes("cipher"), bytes32("commit"));
    }

    // ---- getSubmission never exposes plaintext (ABI-level guarantee) ----

    function test_GetSubmissionReturnsCiphertextTuple() public {
        vm.prank(alice);
        judge.submitCiphertext(bountyId, bytes("cipher"), bytes32("commit"));

        (address submitter, bytes memory ciphertext, bytes32 answerCommitment) =
            judge.getSubmission(bountyId, 0);
        assertEq(submitter, alice);
        assertEq(ciphertext, bytes("cipher"));
        assertEq(answerCommitment, bytes32("commit"));
    }

    // ---- judgeAll guards ----

    function test_JudgeAllBeforeDeadlineReverts() public {
        vm.prank(alice);
        judge.submitCiphertext(bountyId, bytes("cipher"), bytes32("commit"));

        vm.prank(owner);
        vm.expectRevert("submission phase not over");
        judge.judgeAll(bountyId, "");
    }

    function test_JudgeAllWithNoSubmissionsReverts() public {
        vm.warp(submissionDeadline + 1);
        vm.prank(owner);
        vm.expectRevert("no submissions");
        judge.judgeAll(bountyId, "");
    }

    function test_JudgeAllNotOwnerReverts() public {
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        vm.expectRevert("not bounty owner");
        judge.judgeAll(bountyId, "");
    }

    // ---- finalizeWinner guards ----

    function test_FinalizeBeforeJudgedReverts() public {
        vm.prank(owner);
        vm.expectRevert("not judged yet");
        judge.finalizeWinner(bountyId, 0);
    }

    // ---- createBounty guards ----

    function test_CreateBountyWithoutRewardReverts() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert("reward required");
        judge.createBounty{value: 0}(
            "bad",
            "rubric",
            block.timestamp + 1 hours,
            teeExecutorPubKey
        );
    }

    function test_CreateBountyWithoutTeePubKeyReverts() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert("tee pubkey required");
        judge.createBounty{value: 0.1 ether}(
            "bad",
            "rubric",
            block.timestamp + 1 hours,
            bytes("")
        );
    }
}
