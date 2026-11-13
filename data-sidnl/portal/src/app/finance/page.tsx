import KpiCard from '@/components/KpiCard';
import Header, { Empty } from '@/components/Header';
import { Trend } from '@/components/Charts';
import { qSafe, inr, num, n } from '@/lib/db';

export const dynamic = 'force-dynamic';

// Invoices, payments, debit notes and the vendor ledger (Zepto payments-portal exports) -> dash.v_fp_invoice_recon etc.
// Payment advice lists supplier-side internal references, so a payment is matched to an invoice by internal_ref.
// A quantity debit note is matched to its invoice by external reference "<invoice no>_QD".
// There is no due date / payment-term column in any export, so OVERDUE amounts are not shown.
export default async function FinancePage() {
  const [s, inv, age, week, dn, pay] = await Promise.all([
    qSafe(`select invoices, invoice_value::float8, pending_value::float8, payments_received::float8, payments, debit_notes_value::float8,
                  mismatch_vs_grn_abs::float8, mismatch_vs_asn_abs::float8, ledger_opening::float8, ledger_closing::float8, as_of::text
             from dash.v_fp_finance_summary limit 1`),
    qSafe(`select invoice_no, internal_ref, po_no, invoice_date::text d, invoice_amount::float8 amt, asn_value::float8 asn, grn_expected_value::float8 grn,
                  invoice_vs_asn_diff::float8 d_asn, invoice_vs_grn_diff::float8 d_grn, qty_debit_note::float8 qd, is_paid,
                  pending_amount::float8 pending, age_days, age_bucket
             from dash.v_fp_invoice_recon order by invoice_date desc, invoice_no desc`),
    qSafe(`select age_bucket, count(*)::int invoices, sum(pending_amount)::float8 pending, sum(invoice_amount)::float8 amt
             from dash.v_fp_invoice_recon group by age_bucket order by min(age_days)`),
    qSafe(`select date_trunc('week', invoice_date)::date::text w, sum(invoice_amount)::float8 amt, count(*)::int invoices
             from dash.v_fp_invoice_recon group by 1 order by 1`),
    qSafe(`select month::text m, kind, notes, amount::float8 from dash.v_fp_debit_note_month order by month, kind`),
    qSafe(`select reference_no, utr_no, array_length(invoice_nos, 1) invoices, net_payment::float8 amt, paid_at::text paid_at
             from dash.fp_payment_advice order by paid_at desc`),
  ]);

  const k = s.rows[0];
  const err = s.error;

  return (
    <div className="space-y-6">
      <Header title="Finance" subtitle="Invoices, payments, debit notes, vendor ledger (first-party Zepto payments exports)" />
      {err && <Empty what={`Finance views could not be read: ${err.slice(0, 160)}. Apply sql/migrations/dash_016_fp_metric_views.sql.`} />}
      {!err && !k && <Empty what="No invoice data loaded yet." />}

      {!err && k && (
        <>
          <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-xs text-amber-800 space-y-1">
            <p>Ledger as of {k.as_of}. Not available (no due date, payment term or dispute data in the exports): overdue amounts and disputed invoices.
               Ageing is by invoice age, not days overdue.</p>
            <p>Pending = invoice amount − matched quantity debit note − payments matched to the invoice. Payments received can cover older invoices that are
               not in this invoice export, so payments are not netted against the {k.invoices} invoices unless the invoice appears in a payment advice.</p>
          </div>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <KpiCard title="Invoice value" value={inr(k.invoice_value)} subtitle={`${k.invoices} invoices booked`} />
            <KpiCard title="Pending (open invoices)" value={inr(k.pending_value)} subtitle="after quantity debit notes" />
            <KpiCard title="Payments received" value={inr(k.payments_received)} subtitle={`${k.payments} payment advices`} />
            <KpiCard title="Debit notes" value={inr(k.debit_notes_value)} subtitle="quantity shortfall + brand-funded discount" />
            <KpiCard title="Invoice vs received goods" value={inr(k.mismatch_vs_grn_abs)} subtitle="sum of |invoice − received qty × cost|" />
            <KpiCard title="Invoice vs shipped (ASN)" value={inr(k.mismatch_vs_asn_abs)} subtitle="sum of |invoice − ASN qty × cost|" />
            <KpiCard title="Ledger balance" value={inr(k.ledger_closing)} subtitle={`opening ${inr(k.ledger_opening)} · negative = Zepto owes the brand`} />
            <KpiCard title="Overdue / disputed" value={null} unavailable subtitle="no due date or dispute data" />
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">Invoice value by week (₹)</h2>
              <Trend data={week.rows} x="w" series={['amt']} suffix="" />
            </div>
            <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
              <h2 className="section-title">Invoice ageing (by invoice age)</h2>
              <table className="data-table">
                <thead><tr><th>Age (days)</th><th>Invoices</th><th>Invoice value</th><th>Pending</th></tr></thead>
                <tbody>{age.rows.map((r: any) => (
                  <tr key={r.age_bucket}><td>{r.age_bucket}</td><td>{r.invoices}</td><td>{inr(r.amt)}</td><td>{inr(r.pending)}</td></tr>))}</tbody>
              </table>
              <h2 className="section-title mt-6">Debit notes by month</h2>
              <table className="data-table">
                <thead><tr><th>Month</th><th>Type</th><th>Notes</th><th>Amount</th></tr></thead>
                <tbody>{dn.rows.map((r: any, i: number) => (
                  <tr key={i}><td>{r.m.slice(0, 7)}</td><td>{r.kind}</td><td>{r.notes}</td><td>{inr(r.amount)}</td></tr>))}</tbody>
              </table>
            </div>
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Invoice details and 3-way check (invoice ↔ shipped ↔ received)</h2>
            <div className="overflow-auto max-h-[28rem]"><table className="data-table">
              <thead><tr><th>Invoice</th><th>PO</th><th>Date</th><th>Invoice</th><th>ASN value</th><th>Received value</th><th>Δ vs ASN</th><th>Δ vs received</th>
                <th>Qty debit note</th><th>Paid</th><th>Pending</th><th>Age</th></tr></thead>
              <tbody>{inv.rows.map((r: any) => (
                <tr key={r.invoice_no}><td>{r.invoice_no}</td><td>{r.po_no}</td><td>{r.d}</td><td>{inr(r.amt, 2)}</td><td>{inr(r.asn, 2)}</td><td>{inr(r.grn, 2)}</td>
                  <td>{r.d_asn == null ? '—' : inr(r.d_asn, 2)}</td><td>{r.d_grn == null ? '—' : inr(r.d_grn, 2)}</td>
                  <td>{r.qd ? inr(r.qd, 2) : '—'}</td><td>{r.is_paid ? 'yes' : 'no'}</td><td>{inr(r.pending, 2)}</td><td>{r.age_days} d</td></tr>))}</tbody>
            </table></div>
            <p className="text-xs text-slate-400 mt-2">
              The invoice is raised on the shipped (ASN) quantity; the quantity debit note recovers the difference to what was received. Δ vs received is the
              amount the invoice exceeds received goods at PO cost (before that debit note).
            </p>
          </div>

          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm">
            <h2 className="section-title">Payments received</h2>
            <table className="data-table">
              <thead><tr><th>Reference</th><th>UTR</th><th>Invoices settled</th><th>Net payment</th><th>Paid</th></tr></thead>
              <tbody>{pay.rows.map((r: any) => (
                <tr key={r.reference_no}><td>{r.reference_no}</td><td>{r.utr_no ?? '—'}</td><td>{num(r.invoices)}</td><td>{inr(r.amt, 2)}</td><td>{r.paid_at.slice(0, 16)}</td></tr>))}</tbody>
            </table>
            <p className="text-xs text-slate-400 mt-2">Times are IST wall-clock as exported. UTR is blank where the bank reference was not provided.</p>
          </div>
        </>
      )}
    </div>
  );
}
