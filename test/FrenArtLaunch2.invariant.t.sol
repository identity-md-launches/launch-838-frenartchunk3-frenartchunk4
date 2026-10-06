// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Launch2Fixture} from "./FrenArtLaunch2.t.sol";

/// @dev These are data contracts, with no withdrawal or accounting API. STOP nevertheless accepts ETH.
///      Model transfers independently and ensure arbitrary calls cannot execute the embedded art.
contract Launch2CallHandler is Test {
    uint256 public constant INITIAL_FUNDS = 1000 ether;
    address[2] public chunks;
    address[3] public actors;
    uint256[2] public received;
    uint256[3] public spent;

    constructor(address c3, address c4) {
        chunks = [c3, c4];
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("launch2 caller ", vm.toString(i)));
            vm.deal(actors[i], INITIAL_FUNDS);
        }
    }

    function callWithData(uint256 which, uint256 actor, uint256 value, bytes calldata data) external {
        _call(which, actor, value, data);
    }

    function sendWithStipend(uint256 which, uint256 actor, uint256 value) external {
        _call(which, actor, value, "");
    }

    function readWithStaticCall(uint256 which, uint256 actor, bytes calldata data) external {
        which = bound(which, 0, 1);
        actor = bound(actor, 0, actors.length - 1);
        vm.prank(actors[actor]);
        (bool ok, bytes memory result) = chunks[which].staticcall{gas: 2300}(data);
        assertTrue(ok, "STOP must also work under STATICCALL");
        assertEq(result.length, 0, "no return data");
    }

    function callWithoutEnoughBalance(uint256 which, uint256 actor, bytes calldata data) external {
        which = bound(which, 0, 1);
        actor = bound(actor, 0, actors.length - 1);
        uint256 balanceBefore = chunks[which].balance;
        uint256 actorBalance = actors[actor].balance;
        vm.prank(actors[actor]);
        (bool ok, bytes memory result) = chunks[which].call{value: actorBalance + 1, gas: 2300}(data);
        assertFalse(ok, "insufficient caller balance");
        assertEq(result.length, 0);
        assertEq(chunks[which].balance, balanceBefore, "failed call cannot transfer ETH");
        assertEq(actors[actor].balance, actorBalance, "failed call cannot debit caller");
    }

    function _call(uint256 which, uint256 actor, uint256 value, bytes memory data) internal {
        which = bound(which, 0, 1);
        actor = bound(actor, 0, actors.length - 1);
        uint256 available = actors[actor].balance;
        value = bound(value, 0, available < 1 ether ? available : 1 ether);
        vm.record();
        vm.recordLogs();
        vm.prank(actors[actor]);
        (bool ok, bytes memory result) = chunks[which].call{value: value, gas: 2300}(data);
        assertTrue(ok, "STOP accepts arbitrary calls including ETH");
        assertEq(result.length, 0);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(chunks[which]);
        assertEq(reads.length, 0, "art must not read storage");
        assertEq(writes.length, 0, "art must not write storage");
        assertEq(vm.getRecordedLogs().length, 0, "art must not emit events");
        received[which] += value;
        spent[actor] += value;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract FrenArtLaunch2InvariantTest is Launch2Fixture {
    Launch2CallHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Launch2CallHandler(launch2[0], launch2[1]);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.callWithData.selector;
        selectors[1] = handler.sendWithStipend.selector;
        selectors[2] = handler.readWithStaticCall.selector;
        selectors[3] = handler.callWithoutEnoughBalance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ArtCodeCannotChange() public view {
        assertEq(launch2[0].codehash, _expectedHash(0));
        assertEq(launch2[1].codehash, _expectedHash(1));
    }

    function invariant_EthEqualsSuccessfulTransfersAndCallersFundEveryWei() public view {
        uint256 total = launch2[0].balance + launch2[1].balance;
        uint256 totalSpent;
        for (uint256 i; i < 2; ++i) {
            assertEq(launch2[i].balance, handler.received(i), "chunk balance equals independent transfer ledger");
        }
        for (uint256 i; i < 3; ++i) {
            uint256 actorBalance = handler.actors(i).balance;
            assertEq(actorBalance + handler.spent(i), handler.INITIAL_FUNDS(), "caller balance conservation");
            total += actorBalance;
            totalSpent += handler.spent(i);
        }
        assertEq(totalSpent, handler.received(0) + handler.received(1), "no unbacked ETH");
        assertEq(total, 3 * handler.INITIAL_FUNDS(), "closed-system conservation");
    }

    function test_HandlerSequencePinsZeroOneWeiAndMaximumPerCall() public {
        handler.callWithData(0, 0, 0, hex"ff");
        handler.sendWithStipend(1, 1, 1);
        handler.callWithData(0, 2, 1 ether, abi.encodeWithSignature("withdraw(uint256)", type(uint256).max));
        handler.readWithStaticCall(1, 0, hex"f2f4ff");
        handler.callWithoutEnoughBalance(0, 1, "");
        handler.callWithoutEnoughBalance(1, 2, hex"ff");
        // Repeat a payload after value has arrived; no hidden initialization or withdrawal can run.
        handler.callWithData(0, 2, 0, abi.encodeWithSignature("withdraw(uint256)", type(uint256).max));
        invariant_ArtCodeCannotChange();
        invariant_EthEqualsSuccessfulTransfersAndCallersFundEveryWei();
        assertEq(launch2[0].balance, 1 ether);
        assertEq(launch2[1].balance, 1);
    }
}
