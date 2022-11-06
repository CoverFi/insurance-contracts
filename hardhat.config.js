require("@nomicfoundation/hardhat-toolbox");
require("dotenv")
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.17",
  networks:{
    gnosis:{
      url: "https://rpc.ankr.com/gnosis",
      accounts:["c6ab15969e15df78f4caf9a6e10517f34c1bb5c7d9fa544e1cc1fe0fcf936625"]
    },
    polygon:{
      url: "https://polygon-mumbai.g.alchemy.com/v2/GviGsz7aaQIKEHGNbsF-zAfkOswKbh_N",
      accounts:["c6ab15969e15df78f4caf9a6e10517f34c1bb5c7d9fa544e1cc1fe0fcf936625"]

    }
  }
};
