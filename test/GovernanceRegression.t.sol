// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MarketTest.t.sol";

contract GovernanceRegressionTest is MarketTest {
    function _proposal(string memory description)
        internal
        returns (uint256 id, address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        targets = new address[](1);
        targets[0] = address(market);
        values = new uint256[](1);
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(Market.setVault, (address(0xdead)));
        vm.prank(admin);
        id = governor.propose(targets, values, calls, description);
    }

    function testLateVoteCannotReviveDefeatedProposal() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        (uint256 id,,,) = _proposal("late vote");
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), 3);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                id,
                IGovernor.ProposalState.Defeated,
                bytes32(uint256(1) << uint8(IGovernor.ProposalState.Active))
            )
        );
        governor.castVote(id, 1);
        assertFalse(governor.hasVoted(id, admin));
        assertEq(uint256(governor.state(id)), 3);
    }

    function testPendingAndExecutedProposalsRejectVotes() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        (uint256 id, address[] memory targets, uint256[] memory values, bytes[] memory calls) = _proposal("lifecycle");
        vm.prank(admin);
        vm.expectRevert();
        governor.castVote(id, 1);
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(admin);
        governor.castVote(id, 1);
        vm.warp(governor.proposalDeadline(id) + 1);
        governor.queue(targets, values, calls, keccak256("lifecycle"));
        governor.execute(targets, values, calls, keccak256("lifecycle"));
        assertEq(market.vault(), address(0xdead));
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(id, 1);
        assertFalse(governor.hasVoted(id, alice));
    }

    function _smallVoters() internal {
        uint256 firstSeller = _register(merchantOwner, address(merchantContract), 1000e6);
        uint256 otherSeller = _register(bob, bob, 1000e6);
        _trade(alice, alice, 0, firstSeller, 1e6);
        _trade(charlie, charlie, 0, otherSeller, 99e6);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function testNonVotersDoNotSatisfyQuorum() public {
        _smallVoters();
        (uint256 id,,,) = _proposal("low turnout");
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, 1);
        vm.prank(merchantOwner);
        governor.castVote(id, 1);
        (, uint256 support, uint256 abstain) = governor.proposalVotes(id);
        assertEq(support, 1 ether);
        assertEq(abstain, 0);
        assertLt(support, governor.quorum(governor.proposalSnapshot(id)));
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), 3);
    }

    function testExplicitAbstentionCountsAsParticipation() public {
        _smallVoters();
        (uint256 id,,,) = _proposal("explicit abstain");
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, 1);
        vm.prank(merchantOwner);
        governor.castVote(id, 1);
        vm.prank(admin);
        governor.castVote(id, 2);
        (, uint256 support, uint256 abstain) = governor.proposalVotes(id);
        assertEq(support, 1 ether);
        assertEq(abstain, 100 ether);
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), 4);
    }

    function testInvalidVoteTypeDoesNotConsumeVote() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        (uint256 id,,,) = _proposal("invalid support");
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(admin);
        vm.expectRevert(IGovernor.GovernorInvalidVoteType.selector);
        governor.castVote(id, 3);
        assertFalse(governor.hasVoted(id, admin));
        vm.prank(admin);
        governor.castVote(id, 1);
    }

    function _voteSplit(uint256 forAmount, uint256 againstAmount) internal returns (uint256 id) {
        uint256 forSeller = _register(merchantOwner, address(merchantContract), 1000e6);
        uint256 againstSeller = _register(bob, bob, 1000e6);
        usdc.mint(admin, 1000e6);
        uint256 idleSeller = _register(admin, admin, 1000e6);
        address idleBuyer = address(0x888);
        usdc.mint(idleBuyer, 100e6);
        _trade(alice, alice, 0, forSeller, forAmount);
        _trade(charlie, charlie, 0, againstSeller, againstAmount);
        _trade(idleBuyer, idleBuyer, 0, idleSeller, 100e6 - forAmount - againstAmount);
        vm.warp(vm.getBlockTimestamp() + 1);
        (id,,,) = _proposal("split vote");
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, 1);
        vm.prank(merchantOwner);
        governor.castVote(id, 1);
        vm.prank(charlie);
        governor.castVote(id, 0);
        vm.prank(bob);
        governor.castVote(id, 0);
    }

    function testAgainstVotesCountTowardQuorumAndExactTwoToOnePasses() public {
        uint256 id = _voteSplit(6e6, 3e6);
        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(id);
        assertEq(forVotes, 6 ether);
        assertEq(againstVotes, 3 ether);
        assertEq(abstainVotes, 0);
        assertLt(forVotes, governor.quorum(governor.proposalSnapshot(id)));
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), 4); // nine participated; six for is exactly twice three against.
    }

    function testQuorumDoesNotReplaceTwoToOneVoteRatio() public {
        uint256 id = _voteSplit(5e6, 3e6);
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), 3); // eight participated, but five is less than twice three.
    }

    function testDeployerCannotBypassGovernor() public {
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), admin));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), admin));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        bytes memory payload = abi.encodeCall(Market.setVault, (address(0xbeef)));
        vm.prank(admin);
        vm.expectRevert();
        timelock.schedule(address(market), 0, payload, bytes32(0), bytes32(0), 0);
    }

    function testHistoricalSupplyUnaffectedByFutureFirstMint() public {
        uint256 past = vm.getBlockTimestamp();
        vm.warp(past + 1);
        uint256 beforeSupply = buyerElection.getPastTotalSupply(past);
        uint256 seller = _register(bob, bob, 1000e6);
        _trade(alice, alice, 0, seller, 1e6);
        assertEq(beforeSupply, 100 ether);
        assertEq(buyerElection.getPastTotalSupply(past), beforeSupply);
        uint256 mintedAt = vm.getBlockTimestamp();
        vm.warp(mintedAt + 1);
        assertEq(buyerElection.getPastTotalSupply(mintedAt), 200 ether);
    }

    function testHistoricalSupplySurvivesBurnToZeroAndRemint() public {
        uint256 seller = _register(bob, bob, 1000e6);
        _trade(alice, alice, 0, seller, 100e6);
        uint256 beforeBurn = vm.getBlockTimestamp();
        vm.warp(beforeBurn + 1);
        vm.prank(address(timelock));
        buyerElection.burn(alice, 1e6);
        uint256 burnedAt = vm.getBlockTimestamp();
        vm.warp(burnedAt + 1);
        assertEq(buyerElection.getPastTotalSupply(beforeBurn), 200 ether);
        assertEq(buyerElection.getPastTotalSupply(burnedAt), 100 ether);
        _trade(alice, alice, 0, seller, 100e6);
        assertEq(buyerElection.getPastTotalSupply(burnedAt), 100 ether);
        uint256 remintedAt = vm.getBlockTimestamp();
        vm.warp(remintedAt + 1);
        assertEq(buyerElection.getPastTotalSupply(remintedAt), 200 ether);
    }

    function testHistoricalSupplyRejectsPresentAndFuture() public {
        vm.expectRevert("Timepoint must be in the past");
        buyerElection.getPastTotalSupply(vm.getBlockTimestamp());
        vm.expectRevert("Timepoint must be in the past");
        buyerElection.getPastTotalSupply(vm.getBlockTimestamp() + 1);
    }
}
