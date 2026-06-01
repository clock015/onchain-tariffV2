// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract GovernorDualConsensusLogic is
    Initializable,
    GovernorUpgradeable
{
    struct ProposalVote {
        uint256 forVotesA;
        uint256 forVotesB;
        uint256 againstVotesA;
        uint256 againstVotesB;
        mapping(address => bool) hasVoted;
    }

    struct DualConsensusStorage {
        IVotes tokenA;
        IVotes tokenB;
        mapping(uint256 => ProposalVote) proposalVotes;
    }

    bytes32 private constant StorageLocation =
        0x6e788c1c4b314948f95406798a3ca86e29780562e541f5343461159954067900;

    function _getDS() private pure returns (DualConsensusStorage storage $) {
        assembly {
            $.slot := StorageLocation
        }
    }

    event DualVoteCast(
        address indexed voter,
        uint256 proposalId,
        uint8 support,
        uint256 weightA,
        uint256 weightB,
        string reason
    );

    function __GovernorDualConsensus_init(
        IVotes _a,
        IVotes _b
    ) internal onlyInitializing {
        DualConsensusStorage storage $ = _getDS();
        $.tokenA = _a;
        $.tokenB = _b;
    }

    function COUNTING_MODE()
        public
        view
        virtual
        override
        returns (string memory)
    {
        return "support=dual-token&quorum=for,abstain";
    }

    function _getVotes(
        address,
        uint256,
        bytes memory
    ) internal view virtual override returns (uint256) {
        return 0;
    }

    function getVotes(
        address,
        uint256
    ) public view virtual override returns (uint256) {
        revert("Use getVotesA/B");
    }

    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason,
        bytes memory params
    ) internal virtual override returns (uint256) {
        DualConsensusStorage storage $ = _getDS();
        uint256 timepoint = proposalSnapshot(proposalId);
        uint256 weightA = $.tokenA.getPastVotes(account, timepoint);
        uint256 weightB = $.tokenB.getPastVotes(account, timepoint);

        // 这里不再关心返回值，因为我们手动处理了 A/B
        _countVote(proposalId, account, support, 0, params);

        emit DualVoteCast(
            account,
            proposalId,
            support,
            weightA,
            weightB,
            reason
        );
        return 0;
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256) {
        uint256 snapshot = clock() - 1;
        require(
            _getDS().tokenA.getPastVotes(_msgSender(), snapshot) >=
                proposalThreshold() ||
                _getDS().tokenB.getPastVotes(_msgSender(), snapshot) >=
                proposalThreshold(),
            "Below threshold"
        );
        return _propose(targets, values, calldatas, description, _msgSender());
    }

    // =============================================================
    // 【终极修复】严格匹配 5.x 签名：包含 returns (uint256)
    // =============================================================
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 /*totalWeight*/,
        bytes memory /*params*/
    ) internal virtual override returns (uint256) {
        DualConsensusStorage storage $ = _getDS();
        ProposalVote storage vote = $.proposalVotes[proposalId];
        require(!vote.hasVoted[account], "Already voted");
        vote.hasVoted[account] = true;

        uint256 timepoint = proposalSnapshot(proposalId);
        uint256 weightA = $.tokenA.getPastVotes(account, timepoint);
        uint256 weightB = $.tokenB.getPastVotes(account, timepoint);

        if (support == 1) {
            // For
            vote.forVotesA += weightA;
            vote.forVotesB += weightB;
        } else if (support == 0) {
            // Against
            vote.againstVotesA += weightA;
            vote.againstVotesB += weightB;
        }

        // 返回该用户在共识模型下的“有效行使权重”
        return Math.min(weightA, weightB);
    }

    function proposalVotes(
        uint256 proposalId
    )
        public
        view
        virtual
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        DualConsensusStorage storage $ = _getDS();
        ProposalVote storage vote = $.proposalVotes[proposalId];
        uint256 timepoint = proposalSnapshot(proposalId);
        uint256 effectiveFor = Math.min(vote.forVotesA, vote.forVotesB);
        uint256 effectiveAgainst = Math.min(
            vote.againstVotesA,
            vote.againstVotesB
        );
        uint256 totalPot = Math.min(
            $.tokenA.getPastTotalSupply(timepoint),
            $.tokenB.getPastTotalSupply(timepoint)
        );
        uint256 effectiveAbstain = totalPot > (effectiveFor + effectiveAgainst)
            ? totalPot - effectiveFor - effectiveAgainst
            : 0;
        return (effectiveAgainst, effectiveFor, effectiveAbstain);
    }

    function _voteSucceeded(
        uint256 proposalId
    ) internal view virtual override returns (bool) {
        (, uint256 f, uint256 a) = proposalVotes(proposalId);
        return f > a;
    }

    function _quorumReached(
        uint256 proposalId
    ) internal view virtual override returns (bool) {
        (, uint256 f, uint256 ab) = proposalVotes(proposalId);
        return (f + ab) >= quorum(proposalSnapshot(proposalId));
    }

    function hasVoted(
        uint256 proposalId,
        address account
    ) public view virtual override returns (bool) {
        return _getDS().proposalVotes[proposalId].hasVoted[account];
    }
}
