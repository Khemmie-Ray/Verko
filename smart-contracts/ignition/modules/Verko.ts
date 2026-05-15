import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const VerkoModule = buildModule("VerkoModule", (m) => {


  const verifier = m.getParameter<string>(
    "verifier",
    process.env.VERIFIER_ADDRESS ?? "0x0000000000000000000000000000000000000001"
  );

  const gDollarToken = m.getParameter<string>(
    "gDollarToken",
   
    process.env.G_DOLLAR_TOKEN ?? "0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c14"
  );

  const arbFeePerVote = m.getParameter<bigint>(
    "arbFeePerVote",
    BigInt(process.env.ARB_FEE_PER_VOTE ?? "10000000000000000000") // 10 G$
  );

  const platformFeeBps = m.getParameter<number>(
    "platformFeeBps",
    Number(process.env.PLATFORM_FEE_BPS ?? "600") // 6 %
  );

  const reputation = m.contract("WorkerReputation", []);

  const arbitration = m.contract("ArbitrationPool", [
    reputation,
    gDollarToken,
    arbFeePerVote,
  ]);


  const escrow = m.contract("TaskEscrow", [
    reputation,
    arbitration,
    verifier,
    platformFeeBps,
  ]);


  m.call(reputation, "setEscrow", [escrow]);
  m.call(arbitration, "setEscrow", [escrow]);

  return { reputation, arbitration, escrow };
});

export default VerkoModule;