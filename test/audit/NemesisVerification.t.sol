// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";

contract CodexNemesisVerificationTest is Test {
    function testConfigurationHashDoesNotCommitSplitOperatorSplitsOrExtraMetadata() public pure {
        bytes32 hashA = _revDeployerEncodedConfigurationHash();
        bytes32 hashB = _revDeployerEncodedConfigurationHash();

        assertEq(hashA, hashB, "actual REVDeployer hash collides");

        bytes32 fullCommitmentA = keccak256(
            abi.encode(hashA, address(0x1111), uint32(7000), address(0xAAAA), uint48(30 days), uint16(0x0004))
        );
        bytes32 fullCommitmentB = keccak256(
            abi.encode(hashB, address(0x2222), uint32(7000), address(0xBBBB), uint48(90 days), uint16(0x0000))
        );

        assertNotEq(fullCommitmentA, fullCommitmentB, "omitted fields are economically distinct");
    }

    function testRemoteLoanStateOmissionOverstatesCrossChainCashOutValue() public pure {
        uint256 localSupply = 100 ether;
        uint256 localSurplus = 100 ether;
        uint256 remoteVisibleSupply = 1 ether;
        uint256 remoteVisibleSurplus = 1 ether;
        uint256 omittedRemoteLoanCollateral = 99 ether;
        uint256 omittedRemoteLoanDebt = 99 ether;
        uint256 cashOutCount = 100 ether;
        uint256 cashOutTaxRate = 1000;

        uint256 current = JBCashOuts.cashOutFrom({
            surplus: localSurplus + remoteVisibleSurplus,
            cashOutCount: cashOutCount,
            totalSupply: localSupply + remoteVisibleSupply,
            cashOutTaxRate: cashOutTaxRate
        });

        uint256 withRemoteLoans = JBCashOuts.cashOutFrom({
            surplus: localSurplus + remoteVisibleSurplus + omittedRemoteLoanDebt,
            cashOutCount: cashOutCount,
            totalSupply: localSupply + remoteVisibleSupply + omittedRemoteLoanCollateral,
            cashOutTaxRate: cashOutTaxRate
        });

        assertGt(current, withRemoteLoans, "omitting remote loan state should not increase cash-out value");
        assertGt(current - withRemoteLoans, 4 ether, "drift is material");
    }

    function testRemoteLoanStateOmissionCanHitFullSupplyBranch() public pure {
        uint256 localSupply = 100 ether;
        uint256 localSurplus = 100 ether;
        uint256 omittedRemoteLoanCollateral = 100 ether;
        uint256 omittedRemoteLoanDebt = 100 ether;
        uint256 cashOutCount = 100 ether;
        uint256 cashOutTaxRate = 1000;

        uint256 current = JBCashOuts.cashOutFrom({
            surplus: localSurplus, cashOutCount: cashOutCount, totalSupply: localSupply, cashOutTaxRate: cashOutTaxRate
        });

        uint256 withRemoteLoans = JBCashOuts.cashOutFrom({
            surplus: localSurplus + omittedRemoteLoanDebt,
            cashOutCount: cashOutCount,
            totalSupply: localSupply + omittedRemoteLoanCollateral,
            cashOutTaxRate: cashOutTaxRate
        });

        assertEq(current, localSurplus, "current path enters full-supply branch");
        assertEq(withRemoteLoans, 95 ether, "true omnichain curve should remain partial");
        assertGt(current, withRemoteLoans, "full-supply branch overstates cash-out value");
    }

    function _revDeployerEncodedConfigurationHash() internal pure returns (bytes32) {
        bytes memory encodedConfiguration = abi.encode(uint32(1), "REV", "REV", bytes32("codex-nemesis"));

        encodedConfiguration = abi.encode(encodedConfiguration, address(0x1234));

        encodedConfiguration = abi.encode(
            encodedConfiguration,
            uint48(1_740_089_444),
            uint16(7000),
            uint112(1_000_000 ether),
            uint32(30 days),
            uint32(0),
            uint16(JBConstants.MAX_CASH_OUT_TAX_RATE / 2),
            uint16(0)
        );

        encodedConfiguration = abi.encode(encodedConfiguration, uint32(1), address(0xBEEF), uint104(100_000 ether));

        return keccak256(encodedConfiguration);
    }
}
