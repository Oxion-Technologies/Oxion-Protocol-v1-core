// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IOxionStorage} from "../src/interfaces/IOxionStorage.sol";
import {PoolManager} from "../src/PoolManager.sol";

/**
 * forge script script/02_DeployPoolManager.s.sol:DeployCLPoolManagerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployPoolManagerScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address oxionStorage = getAddressFromConfig("OxionStorage");
        console.log("OxionStorage address: ", address(oxionStorage));

        PoolManager poolManager = new PoolManager(IOxionStorage(address(oxionStorage)), 500000);
        console.log("PoolManager contract deployed at ", address(poolManager));

        console.log("Registering PoolManager");
        IOxionStorage(address(oxionStorage)).registerPoolManager(address(poolManager));

        vm.stopBroadcast();
    }
}
