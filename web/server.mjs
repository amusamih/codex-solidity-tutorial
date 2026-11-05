import http from 'node:http';
import { readFile, appendFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const directory = path.dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(await readFile(path.join(directory, 'config.json'), 'utf8'));
const rpcAddress = new URL(config.rpcUrl);
if (!['127.0.0.1', 'localhost', '[::1]'].includes(rpcAddress.hostname)) throw new Error('This demo accepts only a loopback Anvil RPC.');
if (![config.vault, config.depositor].every((address) => /^0x[0-9a-fA-F]{40}$/.test(address))) throw new Error('Invalid vault/depositor configuration.');
const port = Number(process.env.PORT || 3000);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid HTTP port.');
const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
const allowedOrigins = new Set([...allowedHosts].map((host) => `http://${host}`));
const logDirectory = path.resolve(directory, '../.logs/web-demo');
await mkdir(logDirectory, { recursive: true });
let sending = false;

function fail(message, status = 400) { return Object.assign(new Error(message), { status }); }
async function rpc(method, params = []) {
  let response;
  try {
    response = await fetch(config.rpcUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }), signal: AbortSignal.timeout(8000),
    });
  } catch { throw fail('Cannot reach Anvil. Start the existing local network on port 8545.', 503); }
  if (!response.ok) throw fail('Anvil returned an HTTP error.', 503);
  const result = await response.json();
  if (result.error) throw fail(result.error.message || 'Anvil rejected the request.');
  return result.result;
}
function amountToWei(amount) {
  if (typeof amount !== 'string' || amount.length > 80 || !/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(amount)) throw fail('Use a plain ETH amount with up to 18 decimal places.');
  const [whole, fraction = ''] = amount.split('.');
  const wei = BigInt(whole) * 10n ** 18n + BigInt(fraction.padEnd(18, '0'));
  if (wei === 0n) throw fail('Amount must be greater than zero.');
  if (wei >= 2n ** 256n) throw fail('Amount is too large.');
  return wei;
}
const hex = (value) => `0x${value.toString(16)}`;
const balanceCalldata = `0x27e235e3${config.depositor.slice(2).padStart(64, '0')}`;

async function assertNetwork() {
  const [client, chain, code, accounts] = await Promise.all([
    rpc('web3_clientVersion'), rpc('eth_chainId'), rpc('eth_getCode', [config.vault, 'latest']), rpc('eth_accounts'),
  ]);
  if (!client.toLowerCase().startsWith('anvil/')) throw fail('The configured endpoint is not Anvil.', 503);
  if (BigInt(chain) !== BigInt(config.chainId)) throw fail('Expected local Anvil chain 31337.', 503);
  if (code === '0x') throw fail('The existing vault is not deployed on this Anvil instance. Check web/config.json.', 503);
  if (!accounts.some((account) => account.toLowerCase() === config.depositor.toLowerCase())) throw fail('The configured depositor is not an unlocked Anvil account.', 503);
}
async function state() {
  await assertNetwork();
  const block = await rpc('eth_blockNumber');
  const [wallet, recorded, held, total] = await Promise.all([
    rpc('eth_getBalance', [config.depositor, block]),
    rpc('eth_call', [{ to: config.vault, data: balanceCalldata }, block]),
    rpc('eth_getBalance', [config.vault, block]),
    rpc('eth_call', [{ to: config.vault, data: '0x7d882097' }, block]),
  ]);
  return {
    vault: config.vault, depositor: config.depositor, chainId: config.chainId,
    block: BigInt(block).toString(), walletWei: BigInt(wallet).toString(), recordedWei: BigInt(recorded).toString(),
    vaultWei: BigInt(held).toString(), totalWei: BigInt(total).toString(),
  };
}
async function transact(action, amount) {
  const wei = amountToWei(amount);
  if (sending) throw fail('A transaction is already pending. Please wait.', 409);
  sending = true;
  try {
    const before = await state();
    if (action === 'withdraw' && wei > BigInt(before.recordedWei)) throw fail('The amount exceeds your vault balance.');
    const transaction = { from: config.depositor, to: config.vault,
      data: action === 'deposit' ? '0xd0e30db0' : `0x2e1a7d4d${wei.toString(16).padStart(64, '0')}`,
      value: action === 'deposit' ? hex(wei) : '0x0',
    };
    const estimatedGas = BigInt(await rpc('eth_estimateGas', [transaction]));
    transaction.gas = hex(estimatedGas * 12n / 10n);
    // Anvil signs locally with the configured unlocked development account.
    const transactionHash = await rpc('eth_sendTransaction', [transaction]);
    let receipt;
    for (let attempt = 0; attempt < 60; attempt++) {
      receipt = await rpc('eth_getTransactionReceipt', [transactionHash]);
      if (receipt) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    if (!receipt) throw fail(`Transaction submitted (${transactionHash}); receipt not yet available. Refresh balances before retrying.`, 504);
    if (BigInt(receipt.status) !== 1n) throw fail(`Transaction reverted: ${transactionHash}`);
    const after = await state();
    const result = { action, amountWei: wei.toString(), transactionHash, receipt, before, state: after };
    await appendFile(path.join(logDirectory, 'transactions.jsonl'), `${JSON.stringify(result)}\n`);
    return result;
  } finally { sending = false; }
}
function sendJson(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
async function readBody(request) {
  let body = '';
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 1024) throw fail('Request body is too large.', 413);
  }
  try { return JSON.parse(body); } catch { throw fail('Invalid JSON request.'); }
}
const staticFiles = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
]);
const server = http.createServer(async (request, response) => {
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'");
  try {
    if (!allowedHosts.has(request.headers.host)) throw fail('Use the local application address.', 403);
    const url = new URL(request.url, `http://${request.headers.host}`);
    if (request.method === 'GET' && url.pathname === '/api/state') return sendJson(response, 200, await state());
    if (request.method === 'POST' && ['/api/deposit', '/api/withdraw'].includes(url.pathname)) {
      if (!allowedOrigins.has(request.headers.origin)) throw fail('Transaction requests must come from the local interface.', 403);
      if (!request.headers['content-type']?.startsWith('application/json')) throw fail('Expected a JSON request.', 415);
      const body = await readBody(request);
      return sendJson(response, 200, await transact(url.pathname.slice(5), body.amount));
    }
    if (request.method === 'GET' && staticFiles.has(url.pathname)) {
      const [filename, contentType] = staticFiles.get(url.pathname);
      const content = await readFile(path.join(directory, 'dist', filename));
      response.writeHead(200, { 'Content-Type': contentType, 'Cache-Control': 'no-store' });
      return response.end(content);
    }
    throw fail('Not found.', 404);
  } catch (error) {
    sendJson(response, error.status || 500, { error: error.status ? error.message : 'The local server encountered an error.' });
    if (!error.status) console.error(error);
  }
});

await assertNetwork();
server.listen(port, '127.0.0.1', () => {
  console.log(`ETH Vault local interface: http://127.0.0.1:${port}`);
  console.log(`Existing vault: ${config.vault}\nDepositor: ${config.depositor}\nRPC: ${config.rpcUrl}`);
  console.log('Anvil signs transactions using its unlocked local test account. Press Ctrl+C to stop the web server.');
});
server.on('error', (error) => { console.error(error.message); process.exitCode = 1; });
process.on('SIGINT', () => server.close(() => process.exit(0)));
