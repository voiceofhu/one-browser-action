import http2 from "node:http2";

const endpoint = process.env.EGRESS_ENDPOINT ?? "";
const match = /^([A-Za-z0-9.-]+):([0-9]+)$/.exec(endpoint);

if (!match) {
  throw new Error("EGRESS_ENDPOINT must use DNS-host:port format");
}

const [, host, portText] = match;
const port = Number(portText);
if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  throw new Error("EGRESS_ENDPOINT port must be between 1 and 65535");
}

const origin = `https://${host}:${port}`;
const session = http2.connect(origin, {
  ALPNProtocols: ["h2"],
  rejectUnauthorized: true,
  servername: host,
});

let finished = false;
const finish = (error) => {
  if (finished) return;
  finished = true;
  clearTimeout(timeout);
  if (error) {
    session.destroy();
    console.error(`Egress readiness check failed for ${endpoint}: ${error.message}`);
    process.exitCode = 1;
    return;
  }
  session.close();
  console.log(`Egress ready: ${endpoint} (trusted TLS, ALPN h2, unauthenticated 407 Bearer)`);
};

const timeout = setTimeout(() => {
  finish(new Error("timed out after 20 seconds"));
}, 20_000);

session.once("error", finish);
session.once("connect", () => {
  if (session.socket.alpnProtocol !== "h2") {
    finish(new Error(`expected ALPN h2, received ${session.socket.alpnProtocol || "none"}`));
    return;
  }

  const request = session.request({
    ":authority": `${host}:${port}`,
    ":method": "GET",
    ":path": "/",
    ":scheme": "https",
  });

  request.once("error", finish);
  request.once("response", (headers) => {
    const status = Number(headers[":status"]);
    const authenticate = headers["proxy-authenticate"];
    const challenge = Array.isArray(authenticate)
      ? authenticate.join(", ")
      : String(authenticate ?? "");

    if (status !== 407 || !/(^|[, ]+)Bearer(?:\s|$)/i.test(challenge)) {
      finish(new Error(`expected 407 with Proxy-Authenticate: Bearer, received ${status || "no status"}`));
      return;
    }
    request.resume();
    request.once("end", () => finish());
  });
  request.end();
});
