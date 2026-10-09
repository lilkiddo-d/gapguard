import Link from 'next/link';

export const metadata = { title: 'Not available in your region — Gapguard' };

export default function BlockedPage() {
  return (
    <div className="prose">
      <h1>Not available in your region</h1>
      <p className="lead">
        Gapguard’s interface is not offered in your location. Cover and insurance-like products are regulated in many
        jurisdictions, so access is restricted here.
      </p>
      <p>
        You can still read the <Link href="/risk">risk disclosure</Link>.
      </p>
    </div>
  );
}
