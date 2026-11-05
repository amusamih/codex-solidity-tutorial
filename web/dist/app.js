const $ = (id) => document.getElementById(id);
let current = null;
let busy = false;

function parseAmount(text) {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(text.trim())) throw new Error('Use a plain ETH amount with up to 18 decimal places.');
  const [whole, fraction = ''] = text.trim().split('.');
  const wei = BigInt(whole) * 10n ** 18n + BigInt(fraction.padEnd(18, '0'));
  if (wei === 0n) throw new Error('Enter an amount greater than zero.');
  if (wei >= 2n ** 256n) throw new Error('That amount is too large.');
  return wei;
}
function formatETH(wei, places = 6) {
  const n = BigInt(wei);
  return `${n / 10n ** 18n}.${(n % 10n ** 18n).toString().padStart(18, '0').slice(0, places)}`;
}
function exactETH(wei) { return formatETH(wei, 18).replace(/\.?0+$/, '') || '0'; }
function status(message, type = '') { $('status').textContent = message; $('status').className = `status ${type}`; }
function validate() {
  let amount;
  let error = '';
  try { amount = parseAmount($('amount').value); } catch (e) { error = e.message; }
  $('input-error').textContent = error;
  $('amount').setAttribute('aria-invalid', String(Boolean(error)));
  $('deposit').disabled = busy || !current || !amount || amount >= BigInt(current.walletWei);
  $('withdraw').disabled = busy || !current || !amount || amount > BigInt(current.recordedWei);
  $('refresh').disabled = busy;
  if (current) $('amount-help').textContent = `Available to withdraw: ${exactETH(current.recordedWei)} ETH. Up to 18 decimal places.`;
}
async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { 'Content-Type': 'application/json', ...options.headers } });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'The request failed.');
  return data;
}
function render(data) {
  current = data;
  for (const [id, value] of [['recorded', data.recordedWei], ['wallet', data.walletWei], ['vault-balance', data.vaultWei], ['total', data.totalWei]]) {
    $(id).textContent = formatETH(value);
    $(id).title = `${exactETH(value)} ETH`;
  }
  $('vault-address').textContent = data.vault;
  $('account-address').textContent = data.depositor;
  $('chain-id').textContent = data.chainId;
  $('connection').textContent = 'Anvil connected';
  $('connection-dot').classList.add('online');
  validate();
}
async function refresh(announce = false) {
  try {
    render(await api('/api/state'));
    if (announce) status('Balances are up to date.');
  } catch (e) {
    current = null;
    $('connection').textContent = 'Disconnected';
    $('connection-dot').classList.remove('online');
    status(e.message, 'error');
    validate();
  }
}
async function transact(action) {
  if (busy) return;
  let amount;
  try { amount = parseAmount($('amount').value); } catch (e) { status(e.message, 'error'); return; }
  busy = true;
  validate();
  status(`${action === 'deposit' ? 'Depositing' : 'Withdrawing'} ${exactETH(amount)} ETH. Waiting for Anvil confirmation…`);
  try {
    const result = await api(`/api/${action}`, { method: 'POST', body: JSON.stringify({ amount: $('amount').value.trim() }) });
    render(result.state);
    const item = document.createElement('li');
    item.className = 'activity-item';
    const main = document.createElement('div');
    main.className = 'activity-main';
    const label = document.createElement('strong');
    label.textContent = `${action === 'deposit' ? 'Deposited' : 'Withdrew'} ${exactETH(amount)} ETH`;
    const badge = document.createElement('span');
    badge.className = 'confirmed';
    badge.textContent = 'Confirmed';
    main.append(label, badge);
    const hash = document.createElement('div');
    hash.className = 'tx-hash';
    hash.textContent = result.transactionHash;
    item.append(main, hash);
    $('activity').prepend(item);
    $('activity-empty').hidden = true;
    status(`${action === 'deposit' ? 'Deposit' : 'Withdrawal'} confirmed. Balances updated.`, 'success');
  } catch (e) {
    status(e.message, 'error');
    await refresh();
  } finally { busy = false; validate(); }
}
$('amount').addEventListener('input', validate);
$('deposit').addEventListener('click', () => transact('deposit'));
$('withdraw').addEventListener('click', () => transact('withdraw'));
$('refresh').addEventListener('click', () => refresh(true));
$('transfer-form').addEventListener('submit', (event) => event.preventDefault());
refresh(true);
setInterval(() => { if (!busy) refresh(); }, 5000);
