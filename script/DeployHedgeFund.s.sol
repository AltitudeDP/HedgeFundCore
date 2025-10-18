// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {HedgeFund} from "../src/HedgeFund.sol";

contract DeployHedgeFund is Script {
    function run() external {
        address owner = vm.envAddress("HEDGE_FUND_OWNER");
        address asset = vm.envAddress("HEDGE_FUND_ASSET");

        string memory shareName = vm.envString("HEDGE_FUND_SHARE_NAME");
        string memory shareSymbol = vm.envString("HEDGE_FUND_SHARE_SYMBOL");
        string memory queueName = vm.envString("HEDGE_FUND_QUEUE_NAME");
        string memory queueSymbol = vm.envString("HEDGE_FUND_QUEUE_SYMBOL");

        vm.startBroadcast();
        HedgeFund fund = new HedgeFund(owner, asset, shareName, shareSymbol, queueName, queueSymbol);
        vm.stopBroadcast();

        console.log("HedgeFund deployed", address(fund));
    }
}
