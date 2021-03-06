require('.'); // import common test scaffolding

const ProxyERC20 = artifacts.require('ProxyERC20');
const Shadows = artifacts.require('Shadows');
const TokenExchanger = artifacts.require('TokenExchanger');

const { toUnit } = require('../utils/testUtils');

contract('ProxyERC20', async accounts => {
	const [deployerAccount, owner, account1, account2, account3] = accounts;

	let shadows, proxyERC20, tokenExchanger;

	beforeEach(async () => {
		proxyERC20 = await ProxyERC20.new(owner, { from: deployerAccount });
		shadows = await Shadows.deployed();
		await shadows.setIntegrationProxy(proxyERC20.address, { from: owner });
		await proxyERC20.setTarget(shadows.address, { from: owner });

		// Deploy an on chain exchanger
		tokenExchanger = await TokenExchanger.new(owner, proxyERC20.address, {
			from: deployerAccount,
		});

		// Give some DOWS to account1 and account2
		await shadows.transfer(account1, toUnit('10000'), {
			from: owner,
		});
		await shadows.transfer(account2, toUnit('10000'), {
			from: owner,
		});

		// Issue 10 xUSD each
		await shadows.issueSynths(toUnit('10'), { from: account1 });
		await shadows.issueSynths(toUnit('10'), { from: account2 });
	});

	it('should setIntegrationProxy on shadows on deployment', async () => {
		const _integrationProxyAddress = await shadows.integrationProxy();
		assert.equal(proxyERC20.address, _integrationProxyAddress);
	});

	it('should setTarget on ProxyERC20 to shadows on deployment', async () => {
		const integrationProxyTarget = await proxyERC20.target();
		assert.equal(shadows.address, integrationProxyTarget);
	});

	it('should tokenExchanger has ProxyERC20 set on deployment', async () => {
		const _integrationProxyAddress = await tokenExchanger.integrationProxy();
		assert.equal(proxyERC20.address, _integrationProxyAddress);
	});

	describe('ProxyERC20 should adhere to ERC20 standard', async () => {
		it('should be able to query ERC20 totalSupply', async () => {
			// Get DOWS totalSupply
			const dowsTotalSupply = await shadows.totalSupply();
			const proxyTotalSupply = await proxyERC20.totalSupply();
			assert.bnEqual(dowsTotalSupply, proxyTotalSupply);
		});

		it('should be able to query ERC20 balanceOf', async () => {
			// Get my DOWS balance
			const myDOWSBalance = await shadows.balanceOf(account1);
			const myProxyBalance = await proxyERC20.balanceOf(account1);
			assert.bnEqual(myProxyBalance, myDOWSBalance);
		});

		it('should be able to call ERC20 approve', async () => {
			const amountToTransfer = toUnit('50');

			// Approve Account2 to spend 50
			const approveTX = await proxyERC20.approve(account2, amountToTransfer, {
				from: account1,
			});
			// Check for Approval event
			assert.eventEqual(approveTX, 'Approval', {
				owner: account1,
				spender: account2,
				value: amountToTransfer,
			});
			// should be able to query ERC20 allowance
			const allowance = await proxyERC20.allowance(account1, account2);

			// Assert we have the same
			assert.bnEqual(allowance, amountToTransfer);
		});

		it('should be able to call ERC20 transferFrom', async () => {
			const amountToTransfer = toUnit('33');

			// Approve Account2 to spend 50
			await proxyERC20.approve(account2, amountToTransfer, { from: account1 });

			// Get Before Transfer Balances
			const account1BalanceBefore = await shadows.balanceOf(account1);
			const account3BalanceBefore = await shadows.balanceOf(account3);

			// Transfer DOWS
			const transferTX = await shadows.transferFrom(account1, account3, amountToTransfer, {
				from: account2,
			});

			// Check for Transfer event
			assert.eventEqual(transferTX, 'Transfer', {
				from: account1,
				to: account3,
				value: amountToTransfer,
			});

			// Get After Transfer Balances
			const account1BalanceAfter = await shadows.balanceOf(account1);
			const account3BalanceAfter = await shadows.balanceOf(account3);

			// Check Balances
			assert.bnEqual(account1BalanceBefore.sub(amountToTransfer), account1BalanceAfter);
			assert.bnEqual(account3BalanceBefore.add(amountToTransfer), account3BalanceAfter);
		});

		it('should be able to call ERC20 transfer', async () => {
			const amountToTransfer = toUnit('44');

			// Get Before Transfer Balances
			const account1BalanceBefore = await shadows.balanceOf(account1);
			const account2BalanceBefore = await shadows.balanceOf(account2);

			const transferTX = await shadows.transfer(account2, amountToTransfer, {
				from: account1,
			});

			// Check for Transfer event
			assert.eventEqual(transferTX, 'Transfer', {
				from: account1,
				to: account2,
				value: amountToTransfer,
			});

			// Get After Transfer Balances
			const account1BalanceAfter = await shadows.balanceOf(account1);
			const account2BalanceAfter = await shadows.balanceOf(account2);

			// Check Balances
			assert.bnEqual(account1BalanceBefore.sub(amountToTransfer), account1BalanceAfter);
			assert.bnEqual(account2BalanceBefore.add(amountToTransfer), account2BalanceAfter);
		});
	});

	describe('third party contracts', async () => {
		it('should be able to query ERC20 balanceOf', async () => {
			// Get account1 DOWS balance direct
			const myDOWSBalance = await shadows.balanceOf(account1);
			// Get account1 DOWS balance via ERC20 Proxy
			const myProxyBalance = await tokenExchanger.checkBalance(account1);
			// Assert Balance with no reverts
			assert.bnEqual(myProxyBalance, myDOWSBalance);
		});

		it('should be able to transferFrom ERC20', async () => {
			const amountToTransfer = toUnit('77');

			// Approve tokenExchanger to spend account1 balance
			const approveTX = await proxyERC20.approve(tokenExchanger.address, amountToTransfer, {
				from: account1,
			});

			// Check for Approval event
			assert.eventEqual(approveTX, 'Approval', {
				owner: account1,
				spender: tokenExchanger.address,
				value: amountToTransfer,
			});

			// should be able to query ERC20 allowance
			const allowance = await proxyERC20.allowance(account1, tokenExchanger.address);

			// Assert we have the allowance
			assert.bnEqual(allowance, amountToTransfer);

			// Get Before Transfer Balances
			const account1BalanceBefore = await shadows.balanceOf(account1);
			const account2BalanceBefore = await shadows.balanceOf(account2);

			// tokenExchanger to transfer Account1's DOWS to Account2
			await tokenExchanger.doTokenSpend(account1, account2, amountToTransfer);

			// Get After Transfer Balances
			const account1BalanceAfter = await shadows.balanceOf(account1);
			const account2BalanceAfter = await shadows.balanceOf(account2);

			// Check Balances
			assert.bnEqual(account1BalanceBefore.sub(amountToTransfer), account1BalanceAfter);
			assert.bnEqual(account2BalanceBefore.add(amountToTransfer), account2BalanceAfter);
		});

		it('should be able to query optional ERC20 decimals', async () => {
			// Get decimals
			const dowsDecimals = await shadows.decimals();
			const dowsDecimalsContract = await tokenExchanger.getDecimals(shadows.address);
			assert.bnEqual(dowsDecimals, dowsDecimalsContract);
		});
	});
});
