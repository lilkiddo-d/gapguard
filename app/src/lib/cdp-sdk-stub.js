// Server-side stub for @coinbase/cdp-sdk. It is only imported by the Node build of @base-org/account
// (subscription owner wallets), which Gapguard never uses. Stubbing avoids bundling its optional deps.
export class CdpClient {
  constructor() {
    throw new Error('@coinbase/cdp-sdk is not available in Gapguard');
  }
}
export default { CdpClient };
