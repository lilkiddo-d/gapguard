import Link from 'next/link';

export const metadata = { title: 'Risk disclosure — Gapguard' };

export default function RiskPage() {
  return (
    <div className="prose">
      <h1>Risk disclosure</h1>
      <p className="lead">
        Please read this page in full. By buying cover or depositing capital you confirm that you understand and accept
        these risks. Nothing here is financial, legal or tax advice.
      </p>

      <h2>1. What Gapguard is — and is not</h2>
      <ul>
        <li>
          Gapguard sells <strong>parametric</strong> cover: it pays a fixed amount when a pre-defined, on-chain
          measurable event occurs. It does not assess, verify or indemnify your actual loss. You may suffer a loss and
          receive nothing, or receive a payout without having suffered a loss.
        </li>
        <li>Gapguard is not an insurance company, broker, bank or investment adviser, and cover is not a deposit.</li>
        <li>
          Gapguard is independent and is not affiliated with, endorsed by, or sponsored by the issuers of the tokens it
          references, by any brokerage, or by the operator of the chain it runs on.
        </li>
      </ul>

      <h2>2. Regulatory and eligibility risk</h2>
      <ul>
        <li>
          Cover and insurance-like products are regulated in many jurisdictions. It may be unlawful for you to buy
          cover or underwrite it where you live. You are solely responsible for complying with your local laws.
        </li>
        <li>
          Access may be restricted by geography and, if enabled by governance, by an allowlist. Restrictions may change
          at any time, including after you buy cover (cover NFTs may become non-transferable to non-allowlisted
          addresses).
        </li>
        <li>Tokenized stocks may not be available to persons in certain jurisdictions, including the United States.</li>
      </ul>

      <h2>3. Trigger and data risk</h2>
      <ul>
        <li>
          Triggers rely on oracle data (Chainlink price feeds), DEX prices (Uniswap v3 TWAPs), token contract state and
          keeper attestations. Any of these can be wrong, delayed, manipulated or unavailable. Payouts follow the data
          the contracts see, even if it later turns out to be wrong.
        </li>
        <li>
          Market schedules (24/5 sessions, DST, holidays) are encoded on-chain. Unusual market closures may change
          when, or whether, an event is measured.
        </li>
        <li>
          Corporate actions (splits, dividends) are reflected in token multipliers and oracle prices; during such
          actions the issuer may pause its oracle, which can delay resolution.
        </li>
        <li>
          Issuer Halt cover depends on keeper attestations and a dispute process (a committee and, once launched,
          bonded token stakers). A wrong dispute outcome can deny or cause a payout.
        </li>
        <li>
          Cover only applies to events that <strong>start</strong> during your cover period. Cover starts at least one
          hour after purchase; buying after an event is known does not cover that event.
        </li>
      </ul>

      <h2>4. Smart-contract and operational risk</h2>
      <ul>
        <li>The contracts may contain bugs. Audits and tests reduce but never eliminate this risk.</li>
        <li>
          A guardian can pause the protocol (including claims) in an emergency; only the 48-hour Timelock can unpause
          or change parameters. Parameter changes can affect future cover and pools.
        </li>
        <li>
          Payouts are made in USDG, a third-party stablecoin. If it loses its peg or is frozen, payouts lose value or
          fail.
        </li>
        <li>Keepers normally pay claims automatically; if they fail, anyone can submit the claim on-chain.</li>
        <li>Expired covers are closed 14 days after their end date and can then no longer be claimed.</li>
      </ul>

      <h2>5. Underwriter risk</h2>
      <ul>
        <li>
          Underwriters can lose up to <strong>100%</strong> of their deposit. Exposure limits per asset and per
          product bound, but do not remove, correlated losses.
        </li>
        <li>
          Withdrawals require a 14-day cooldown, are limited to unlocked capital, and are frozen while events are
          pending or settling. You may be unable to exit when you want to.
        </li>
        <li>Premium income is variable and past APY does not predict future returns.</li>
      </ul>

      <h2>6. Token risk</h2>
      <ul>
        <li>
          The project token is launched separately and may not exist. Until governance wires it in, all token
          features are disabled. Staked tokens used to dispute attestations are slashable.
        </li>
      </ul>

      <p>
        Questions? Read the protocol documentation and threat model in the repository before using Gapguard.{' '}
        <Link href="/">Back to the app</Link>.
      </p>
    </div>
  );
}
