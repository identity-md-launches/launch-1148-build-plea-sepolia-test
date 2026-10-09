// Hand-written ABIs for the reused contracts whose source is not in this
// repository. Selectors were checked against the deployed Sepolia bytecode:
// TestIMD faucet() 0xde5f72fd, Stacker stackedBy(address,address) 0xad5e3f1a,
// PoolSwapTest swap(...) 0x2229d0b4.
export const testImdAbi = [
  { type: "function", name: "faucet", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "balanceOf", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "allowance", inputs: [{ name: "o", type: "address" }, { name: "s", type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "approve", inputs: [{ name: "s", type: "address" }, { name: "v", type: "uint256" }], outputs: [{ type: "bool" }], stateMutability: "nonpayable" },
  { type: "function", name: "decimals", inputs: [], outputs: [{ type: "uint8" }], stateMutability: "view" },
  { type: "event", name: "Transfer", inputs: [{ name: "from", type: "address", indexed: true }, { name: "to", type: "address", indexed: true }, { name: "value", type: "uint256", indexed: false }], anonymous: false },
  { type: "error", name: "ERC20InsufficientBalance", inputs: [{ name: "sender", type: "address" }, { name: "balance", type: "uint256" }, { name: "needed", type: "uint256" }] },
  { type: "error", name: "ERC20InsufficientAllowance", inputs: [{ name: "spender", type: "address" }, { name: "allowance", type: "uint256" }, { name: "needed", type: "uint256" }] },
] as const;

export const stackerAbi = [
  { type: "function", name: "stackedBy", inputs: [{ name: "project", type: "address" }, { name: "user", type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;

export const poolSwapTestAbi = [
  {
    type: "function",
    name: "swap",
    stateMutability: "payable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "zeroForOne", type: "bool" },
          { name: "amountSpecified", type: "int256" },
          { name: "sqrtPriceLimitX96", type: "uint160" },
        ],
      },
      {
        name: "testSettings",
        type: "tuple",
        components: [
          { name: "takeClaims", type: "bool" },
          { name: "settleUsingBurn", type: "bool" },
        ],
      },
      { name: "hookData", type: "bytes" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
] as const;

// Errors raised by the Uniswap v4 PoolManager that a buy can surface.
export const poolManagerErrorsAbi = [
  { type: "error", name: "PriceLimitAlreadyExceeded", inputs: [{ type: "uint160" }, { type: "uint160" }] },
  { type: "error", name: "PriceLimitOutOfBounds", inputs: [{ type: "uint160" }] },
  { type: "error", name: "SwapAmountCannotBeZero", inputs: [] },
  { type: "error", name: "CurrencyNotSettled", inputs: [] },
  { type: "error", name: "ManagerLocked", inputs: [] },
  { type: "error", name: "PoolNotInitialized", inputs: [] },
  {
    type: "error",
    name: "WrappedError",
    inputs: [
      { name: "target", type: "address" },
      { name: "selector", type: "bytes4" },
      { name: "reason", type: "bytes" },
      { name: "details", type: "bytes" },
    ],
  },
  { type: "error", name: "HookCallFailed", inputs: [] },
] as const;
