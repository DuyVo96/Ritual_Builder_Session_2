// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudge} from "./AIJudge.sol";

contract AIJudgeTest is Test {
    AIJudge judge;

    address owner = address(1);
    address alice = address(2);
    address bob   = address(3);

    uint256 submissionDeadline;
    uint256 revealDeadline;
    uint256 bountyId;

    function setUp() public {
        judge = new AIJudge();
        submissionDeadline = block.timestamp + 1 hours;
        revealDeadline     = block.timestamp + 2 hours;

        vm.deal(owner, 10 ether);
        vm.prank(owner);
        bountyId = judge.createBounty{value: 1 ether}(
            "Test bounty",
            "rubric: be correct",
            submissionDeadline,
            revealDeadline
        );
    }

    function _commitment(
        address sender,
        string memory answer,
        bytes32 salt,
        uint256 id
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, sender, id));
    }

    // ---- happy path ----

    function test_ValidCommitAndReveal() public {
        bytes32 salt   = bytes32("mysalt");
        string memory answer = "My answer";

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(alice, answer, salt, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, answer, salt);

        (address submitter, string memory revealed) = judge.getSubmission(bountyId, 0);
        assertEq(submitter, alice);
        assertEq(revealed, answer);
    }

    function test_CommitmentCountIncrements() public {
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(alice, "a", bytes32("s1"), bountyId));

        vm.prank(bob);
        judge.submitCommitment(bountyId, _commitment(bob, "b", bytes32("s2"), bountyId));

        (,,,,,,,,, uint256 commitmentCount,,) = judge.getBounty(bountyId);
        assertEq(commitmentCount, 2);
    }

    // ---- commit phase guards ----

    function test_CommitAfterDeadlineReverts() public {
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        vm.expectRevert("submission phase closed");
        judge.submitCommitment(bountyId, bytes32("anything"));
    }

    function test_DoubleCommitReverts() public {
        bytes32 c = _commitment(alice, "ans", bytes32("salt"), bountyId);
        vm.prank(alice);
        judge.submitCommitment(bountyId, c);

        vm.prank(alice);
        vm.expectRevert("already committed");
        judge.submitCommitment(bountyId, c);
    }

    // ---- reveal phase guards ----

    function test_RevealBeforeSubmissionDeadlineReverts() public {
        bytes32 salt = bytes32("salt");
        string memory answer = "answer";
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(alice, answer, salt, bountyId));

        vm.prank(alice);
        vm.expectRevert("not in reveal phase");
        judge.revealAnswer(bountyId, answer, salt);
    }

    function test_RevealAfterRevealDeadlineReverts() public {
        bytes32 salt = bytes32("salt");
        string memory answer = "answer";
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(alice, answer, salt, bountyId));

        vm.warp(revealDeadline + 1);
        vm.prank(alice);
        vm.expectRevert("reveal phase closed");
        judge.revealAnswer(bountyId, answer, salt);
    }

    function test_RevealWithWrongSaltReverts() public {
        bytes32 salt = bytes32("salt");
        string memory answer = "answer";
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(alice, answer, salt, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(bountyId, answer, bytes32("wrong_salt"));
    }

    function test_RevealWithWrongAnswerReverts() public {
        bytes32 salt = bytes32("salt");
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(alice, "real answer", salt, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        vm.expectRevert("commitment mismatch");
        judge.revealAnswer(bountyId, "different answer", salt);
    }

    function test_DoubleRevealReverts() public {
        bytes32 salt = bytes32("salt");
        string memory answer = "answer";
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(alice, answer, salt, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, answer, salt);

        vm.prank(alice);
        vm.expectRevert("already revealed");
        judge.revealAnswer(bountyId, answer, salt);
    }

    function test_RevealWithoutCommitReverts() public {
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        vm.expectRevert("no commitment found");
        judge.revealAnswer(bountyId, "answer", bytes32("salt"));
    }

    // ---- judgeAll guard ----

    function test_JudgeAllBeforeRevealDeadlineReverts() public {
        vm.warp(submissionDeadline + 1);
        vm.prank(owner);
        vm.expectRevert("reveal phase not over");
        judge.judgeAll(bountyId, "");
    }

    // ---- createBounty guard ----

    function test_CreateBountyWithRevealBeforeDeadlineReverts() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert("reveal deadline must be after deadline");
        judge.createBounty{value: 0.1 ether}(
            "bad",
            "rubric",
            block.timestamp + 2 hours,
            block.timestamp + 1 hours
        );
    }
}
