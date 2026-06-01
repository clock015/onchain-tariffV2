// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GovernorDualConsensusLogic.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract FinalGovernor is
    Initializable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorDualConsensusLogic,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable
{
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IVotes _tokenA,
        IVotes _tokenB,
        TimelockControllerUpgradeable _timelock
    ) public initializer {
        __Governor_init("DualDAO");
        __GovernorSettings_init(7200, 50400, 100 ether);
        __GovernorTimelockControl_init(_timelock);
        __GovernorDualConsensus_init(_tokenA, _tokenB);
        __GovernorVotes_init(_tokenA);
        __GovernorVotesQuorumFraction_init(4);
    }

    // 显式重载 _getVotes
    function _getVotes(
        address account,
        uint256 timepoint,
        bytes memory params
    )
        internal
        view
        override(
            GovernorUpgradeable,
            GovernorVotesUpgradeable,
            GovernorDualConsensusLogic
        )
        returns (uint256)
    {
        return GovernorDualConsensusLogic._getVotes(account, timepoint, params);
    }

    // 显式重载 getVotes (从接口列表移除 IGovernor，因为接口不能出现在 override 列表)
    function getVotes(
        address account,
        uint256 timepoint
    )
        public
        view
        override(GovernorUpgradeable, GovernorDualConsensusLogic)
        returns (uint256)
    {
        return GovernorDualConsensusLogic.getVotes(account, timepoint);
    }

    // 显式重载 _castVote
    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason,
        bytes memory params
    )
        internal
        override(GovernorUpgradeable, GovernorDualConsensusLogic)
        returns (uint256)
    {
        return
            GovernorDualConsensusLogic._castVote(
                proposalId,
                account,
                support,
                reason,
                params
            );
    }

    // 显式重载 propose (同样移除 IGovernor)
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    )
        public
        override(GovernorUpgradeable, GovernorDualConsensusLogic)
        returns (uint256)
    {
        return
            GovernorDualConsensusLogic.propose(
                targets,
                values,
                calldatas,
                description
            );
    }

    // 其他逻辑保持 super 调用
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyGovernance {}

    function state(
        uint256 proposalId
    )
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(
        uint256 proposalId
    )
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint48)
    {
        return
            super._queueOperations(
                proposalId,
                targets,
                values,
                calldatas,
                descriptionHash
            );
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
    {
        super._executeOperations(
            proposalId,
            targets,
            values,
            calldatas,
            descriptionHash
        );
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint256)
    {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
}
