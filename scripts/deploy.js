// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
const hre = require("hardhat");

async function main() {
  


  const CoverFi = await hre.ethers.getContractFactory("CoverFiGnosis");

  const coverFi = await CoverFi.deploy("0xeF684C38F94F48775959ECf2012D7E864ffb9dd4", "0xB579C5ba3Bc8EA2F5DD5622f1a5EaC6282516fB1", "0x0000000000000000000000000000000000000000");
  await coverFi.deployed();

  console.log(
    `CoverFi deployed to ${coverFi.address}`
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
