// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenArtIndex} from "src/FrenArtIndex.sol";
import {FrenRenderer} from "src/FrenRenderer.sol";
import {
    FrenArtChunk1,
    FrenArtChunk2,
    FrenArtChunk3,
    FrenArtChunk4,
    FrenArtChunk5,
    FrenArtChunk6,
    FrenArtChunk7
} from "src/FrenArtChunks.sol";

/// @dev Exposes CREATE2's failure result, including failures before runtime exists.
contract Launch2CreationProbe {
    function deploy(bytes memory initcode, bytes32 salt) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(callvalue(), add(initcode, 32), mload(initcode), salt)
        }
    }
}

/// @dev Only exposes the production reader, so layer comparisons test its real unframing logic.
contract Launch2LayerReader is FrenRenderer {
    constructor(address[7] memory c) FrenRenderer(c[0], c[1], c[2], c[3], c[4], c[5], c[6]) {}

    function layer(uint256 index) external view returns (bytes memory) {
        return _entry(index);
    }
}

abstract contract Launch2Fixture is Test {
    address[2] internal launch2;
    string internal constant ART = "script/art/data/";

    function setUp() public virtual {
        // The assignment's deployment order, with no constructor arguments.
        launch2[0] = address(new FrenArtChunk3());
        launch2[1] = address(new FrenArtChunk4());
    }

    function _initcode(uint256 which) internal pure returns (bytes memory) {
        return which == 0 ? type(FrenArtChunk3).creationCode : type(FrenArtChunk4).creationCode;
    }

    function _expectedHash(uint256 which) internal pure returns (bytes32 result) {
        bytes memory hashes = FrenArtIndex.CHUNK_HASHES;
        assembly ("memory-safe") {
            result := mload(add(add(hashes, 32), mul(add(which, 2), 32)))
        }
    }

    function _sourceLayers(uint256 first, uint256 end) internal view returns (bytes memory result) {
        string[] memory names = vm.parseJsonStringArray(vm.readFile(string.concat(ART, "manifest.json")), ".layers");
        for (uint256 i = first; i < end; ++i) {
            result = bytes.concat(result, vm.readFileBinary(string.concat(ART, "layers/", names[i], ".bin")));
        }
    }
}

/// forge-config: default.fuzz.runs = 128
contract FrenArtLaunch2Test is Launch2Fixture {
    function test_ExactSizesHashesAndDeploymentLimits() public view {
        bytes memory sizes = FrenArtIndex.CHUNK_SIZES;
        for (uint256 i; i < 2; ++i) {
            uint256 size = uint256(uint8(sizes[4 + 2 * i])) * 256 + uint8(sizes[5 + 2 * i]);
            assertEq(launch2[i].code.length, size, "index size");
            assertEq(launch2[i].codehash, _expectedHash(i), "renderer's required hash");
            assertEq(launch2[i].code[0], bytes1(0), "STOP");
            assertEq(launch2[i].balance, 0, "zero-value launch");
            assertLe(size, 24_576, "EIP-170");
            assertLe(_initcode(i).length, 49_152, "EIP-3860");
        }
        assertEq(launch2[0].code.length, 23_479);
        assertEq(launch2[1].code.length, 21_187);
    }

    function test_Chunk3ContainsEverySourceByteWithoutFrames() public view {
        // Independent oracle: the exported art files, not a second deployment of the same contract.
        bytes memory source = _sourceLayers(25, 37); // face25 through face36
        assertEq(source.length, 23_478);
        assertEq((FrenArtIndex.FRAMED >> 2) & 1, 0);
        assertEq(launch2[0].code, bytes.concat(hex"00", source));
    }

    function test_Chunk4FramesPreserveEverySourceByteAndZeroPadOnlyTheTail() public view {
        bytes memory source = _sourceLayers(37, 61); // face37 through bg1
        bytes memory runtime = launch2[1].code;
        assertEq(source.length, 20_538);
        assertEq((FrenArtIndex.FRAMED >> 3) & 1, 1);
        assertEq((runtime.length - 1) % 33, 0, "complete PUSH32 frames");
        uint256 frames = (runtime.length - 1) / 33;
        assertEq(frames, (source.length + 31) / 32, "no missing or extra frame");
        bytes memory decoded = new bytes(frames * 32);
        for (uint256 f; f < frames; ++f) {
            assertEq(runtime[1 + 33 * f], bytes1(0x7f), "PUSH32 marker");
            for (uint256 j; j < 32; ++j) {
                decoded[32 * f + j] = runtime[2 + 33 * f + j];
            }
        }
        assertEq(decoded.length - source.length, 6, "last frame has six padding bytes");
        assertEq(decoded, bytes.concat(source, new bytes(6)), "decoded art and canonical padding");
    }

    function testFuzz_Create2IdentityAndCollisionLeaveBothChunksIntact(bytes32 salt) public {
        Launch2CreationProbe factory = new Launch2CreationProbe();
        address[2] memory deployed;
        for (uint256 i; i < 2; ++i) {
            bytes memory initcode = _initcode(i);
            deployed[i] = factory.deploy(initcode, salt);
            assertEq(deployed[i], vm.computeCreate2Address(salt, keccak256(initcode), address(factory)));
            assertEq(deployed[i].codehash, _expectedHash(i));
            assertEq(deployed[i].balance, 0);
        }
        assertNotEq(deployed[0], deployed[1], "different initcode, same factory and salt");
        for (uint256 i; i < 2; ++i) {
            // Collision consumes the forwarded creation gas; limit it so the test can check the result.
            assertEq(factory.deploy{gas: 500_000}(_initcode(i), salt), address(0), "duplicate deployment");
            assertEq(deployed[i].codehash, _expectedHash(i), "collision must not replace art");
        }
    }

    function test_ConstructorsRejectOneWeiAndMaximumValue() public {
        for (uint256 i; i < 2; ++i) {
            _assertConstructorRejectsValue(i, 1);
            _assertConstructorRejectsValue(i, type(uint256).max);
        }
    }

    function testFuzz_ConstructorsRejectNonzeroValue(bool chunk4, uint256 value) public {
        _assertConstructorRejectsValue(chunk4 ? 1 : 0, bound(value, 1, type(uint256).max));
    }

    function _assertConstructorRejectsValue(uint256 which, uint256 value) internal {
        Launch2CreationProbe factory = new Launch2CreationProbe();
        bytes memory initcode = _initcode(which);
        bytes32 salt = keccak256("nonpayable constructor");
        address predicted = vm.computeCreate2Address(salt, keccak256(initcode), address(factory));
        vm.deal(address(this), value);
        assertEq(factory.deploy{value: value}(initcode, salt), address(0), "nonpayable constructor must fail");
        assertEq(predicted.code.length, 0, "failed creation has no runtime");
        assertEq(predicted.balance, 0, "failed creation receives no ETH");
        assertEq(address(factory).balance, value, "creation value returned to factory");
        assertEq(factory.deploy(initcode, salt), predicted, "failed creation does not reserve CREATE2 address");
        assertEq(predicted.codehash, _expectedHash(which), "zero-value retry succeeds");
        assertEq(predicted.balance, 0);
    }

    function test_EmptyAndOpcodeLikeCalldataStopWithoutEffects() public {
        bytes[4] memory payloads = [
            bytes(""),
            hex"ff",
            hex"f2f4fffe",
            abi.encodeWithSignature("withdraw(address,uint256)", address(this), type(uint256).max)
        ];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < payloads.length; ++j) {
                _assertInertCall(i, address(0xA11CE), payloads[j]);
            }
        }
    }

    function testFuzz_ArbitraryCalldataAndCallerCannotExecuteArt(bool chunk4, address caller, bytes memory data)
        public
    {
        _assertInertCall(chunk4 ? 1 : 0, caller, data);
    }

    function _assertInertCall(uint256 which, address caller, bytes memory data) internal {
        address target = launch2[which];
        vm.record();
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory result) = target.call{gas: 2300}(data);
        assertTrue(ok, "STOP accepts any calldata");
        assertEq(result.length, 0, "no returned art or ABI response");
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(target);
        assertEq(reads.length, 0, "no storage reads");
        assertEq(writes.length, 0, "no storage writes");
        assertEq(vm.getRecordedLogs().length, 0, "no events");
        (ok, result) = target.staticcall{gas: 2300}(data);
        assertTrue(ok, "static read also stops");
        assertEq(result.length, 0);
        assertEq(target.codehash, _expectedHash(which));
        assertEq(target.balance, 0);
    }
}

/// forge-config: default.fuzz.runs = 128
contract FrenArtLaunch2RendererTest is Launch2Fixture {
    address[7] internal art;
    Launch2LayerReader internal reader;

    function setUp() public override {
        super.setUp();
        art = [
            address(new FrenArtChunk1()),
            address(new FrenArtChunk2()),
            launch2[0],
            launch2[1],
            address(new FrenArtChunk5()),
            address(new FrenArtChunk6()),
            address(new FrenArtChunk7())
        ];
        reader = new Launch2LayerReader(art);
    }

    function test_ProductionReaderRecoversEveryLaunch2Layer() public view {
        string[] memory names = vm.parseJsonStringArray(vm.readFile(string.concat(ART, "manifest.json")), ".layers");
        for (uint256 i = 25; i < 61; ++i) {
            assertEq(reader.layer(i), vm.readFileBinary(string.concat(ART, "layers/", names[i], ".bin")), names[i]);
        }
        assertEq(reader.chunk3(), launch2[0]);
        assertEq(reader.chunk4(), launch2[1]);
    }

    function test_RendererRejectsSwappedAndDuplicatedLaunch2Chunks() public {
        art[2] = launch2[1];
        art[3] = launch2[0];
        _expectBadArt();
        art[2] = launch2[0];
        _expectBadArt(); // chunk3 in both positions
        art[2] = launch2[1];
        art[3] = launch2[1];
        _expectBadArt(); // chunk4 in both positions
    }

    function test_RendererRejectsMissingOrStopOnlyLaunch2Chunks() public {
        address empty = makeAddr("missing launch2 art");
        address stopOnly = makeAddr("STOP without art");
        vm.etch(stopOnly, hex"00");
        for (uint256 i; i < 2; ++i) {
            art[i + 2] = address(0);
            _expectBadArt();
            art[i + 2] = empty;
            _expectBadArt();
            art[i + 2] = stopOnly;
            _expectBadArt();
            art[i + 2] = launch2[i];
        }
    }

    function testFuzz_RendererRejectsSameLengthSingleByteCorruption(bool chunk4, uint256 offset, uint8 delta) public {
        uint256 which = chunk4 ? 1 : 0;
        bytes memory corrupted = launch2[which].code;
        offset = bound(offset, 0, corrupted.length - 1);
        corrupted[offset] ^= bytes1(uint8(bound(delta, 1, 255)));
        vm.etch(launch2[which], corrupted);
        // Same size, guaranteed changed byte: checking only length or STOP would miss this.
        _expectBadArt();
    }

    function test_RendererRejectsChangedStopFrameMarkerAndFinalPadding() public {
        bytes memory pristine = launch2[1].code;
        uint256[3] memory offsets = [uint256(0), uint256(1), pristine.length - 1];
        for (uint256 i; i < offsets.length; ++i) {
            bytes memory corrupted = bytes.concat(pristine);
            corrupted[offsets[i]] ^= bytes1(0x01);
            vm.etch(launch2[1], corrupted);
            _expectBadArt();
        }
    }

    function test_RendererRejectsUnframedChunk4EvenWithCorrectArt() public {
        vm.etch(launch2[1], bytes.concat(hex"00", _sourceLayers(37, 61)));
        _expectBadArt();
    }

    function test_RendererRejectsTruncatedOrExtendedChunks() public {
        for (uint256 i; i < 2; ++i) {
            bytes memory pristine = launch2[i].code;
            bytes memory shortened = bytes.concat(pristine);
            assembly ("memory-safe") {
                mstore(shortened, sub(mload(shortened), 1))
            }
            vm.etch(launch2[i], shortened);
            _expectBadArt();
            vm.etch(launch2[i], bytes.concat(pristine, hex"00"));
            _expectBadArt();
            vm.etch(launch2[i], pristine);
        }
    }

    function _expectBadArt() internal {
        vm.expectRevert(FrenRenderer.BadArt.selector);
        new FrenRenderer(art[0], art[1], art[2], art[3], art[4], art[5], art[6]);
    }
}
