import hardhatToolboxMochaEthersPlugin from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxMochaEthersPlugin],

  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      production: {
        version: "0.8.28",
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },

  networks: {
    // Local simulators 
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },

    // Existing testnet 
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },

    // Celo Alfajores Testnet 
    alfajores: {
      type: "http",
      chainType: "l1",
      url: "https://alfajores-forno.celo-testnet.org",
      accounts: [configVariable("CELO_PRIVATE_KEY")],
      gasPrice: 1_000_000_000,
    },

    // Celo Mainnet
    celo: {
      type: "http",
      chainType: "l1",
      url: "https://forno.celo.org",
      accounts: [configVariable("CELO_PRIVATE_KEY")],
      gasPrice: 1_000_000_000,
    },
  },
});