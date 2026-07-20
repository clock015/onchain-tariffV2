// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/RightsToken/GenesisSeatToken.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatToken.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProportionalElectionBatchBurnTest is Test {
    ProportionalElection private election;
    SeatToken private activeToken;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant OUTSIDER = address(0xBAD);

    event SeatBurned(
        uint256 indexed roundId,
        address indexed from,
        uint256 amount
    );

    function setUp() public {
        vm.warp(365 days + 30 days);

        SeatTokenFactory factory = new SeatTokenFactory();
        GenesisSeatToken genesis = new GenesisSeatToken(
            "Council Seat 0",
            "CS",
            address(this)
        );

        ProportionalElection implementation = new ProportionalElection();
        election = ProportionalElection(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        ProportionalElection.initialize,
                        (address(factory), address(this), address(genesis))
                    )
                )
            )
        );

        genesis.setMinter(address(election));
        factory.setElectionContract(address(election));

        election.mint(ALICE, 100 ether);
        election.mint(BOB, 200 ether);

        (address token, ) = election.rounds(1);
        activeToken = SeatToken(token);
    }

    function testBatchBurnBurnsEveryAccountAndUpdatesVotes() public {
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 50 ether;

        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(1, ALICE, 30 ether);
        vm.expectEmit(true, true, false, true, address(election));
        emit SeatBurned(1, BOB, 50 ether);

        election.batchBurn(accounts, amounts);

        assertEq(activeToken.balanceOf(ALICE), 70 ether);
        assertEq(activeToken.balanceOf(BOB), 150 ether);
        assertEq(activeToken.getVotes(ALICE), 70 ether);
        assertEq(activeToken.getVotes(BOB), 150 ether);
        assertEq(activeToken.totalSupply(), 220 ether);
    }

    function testBatchBurnRevertsAtomicallyWhenLengthsDiffer() public {
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 30 ether;

        vm.expectRevert(SeatToken.BatchLengthMismatch.selector);
        election.batchBurn(accounts, amounts);

        assertEq(activeToken.balanceOf(ALICE), 100 ether);
        assertEq(activeToken.balanceOf(BOB), 200 ether);
    }

    function testBatchBurnIsOwnerOnly() public {
        address[] memory accounts = new address[](1);
        accounts[0] = ALICE;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(OUTSIDER);
        vm.expectRevert();
        election.batchBurn(accounts, amounts);
    }
}
