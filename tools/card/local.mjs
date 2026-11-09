import { spawn } from "node:child_process";
import { once } from "node:events";
import net from "node:net";
const server = net.createServer();
server.listen(0, "127.0.0.1");
await once(server, "listening");
const port = server.address().port;
server.close();
await once(server, "close");
const rpc = "http://127.0.0.1:" + port;
const node = spawn(
  "anvil",
  [
    "--host",
    "127.0.0.1",
    "--port",
    String(port),
    "--hardfork",
    "cancun",
    "--gas-limit",
    "100000000",
    "--silent",
  ],
  { stdio: ["ignore", "ignore", "inherit"] },
);
try {
  let ready = false;
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(rpc, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "eth_chainId",
          params: [],
        }),
      });
      if ((await r.json()).result === "0x7a69") {
        ready = true;
        break;
      }
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  if (!ready) throw Error("Local Anvil did not start");
  const proc = spawn(
    process.execPath,
    ["tools/card/chain.mjs", "local", "31337"],
    {
      env: { ...process.env, DEPLOYER_KEY: "", RPC_URL: rpc },
      stdio: "inherit",
    },
  );
  const [code] = await once(proc, "exit");
  if (code !== 0) process.exitCode = 1;
} finally {
  node.kill();
}
