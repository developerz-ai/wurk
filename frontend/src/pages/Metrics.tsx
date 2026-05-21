import { useQuery } from '@tanstack/react-query';
import { useState, useEffect } from 'react';
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts';
import { t } from '../i18n';
import { truncate } from '../utils';

interface TopJob {
  class: string;
  total: number;
  failed: number;
  avg_ms: number;
  p99_ms: number;
}

interface MetricsResponse {
  minutes: number;
  top_jobs: TopJob[];
}

const MINUTE_OPTIONS = [15, 30, 60, 120, 480] as const;

export default function Metrics() {
  const [minutes, setMinutes] = useState(60);

  useEffect(() => {
    document.title = `${t('nav.metrics')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<MetricsResponse>({
    queryKey: ['metrics', minutes],
    queryFn: () =>
      fetch(`/wurk/api/metrics?minutes=${minutes}`).then(
        (r) => r.json() as Promise<MetricsResponse>
      ),
    refetchInterval: 30000,
  });

  const chartData = (data?.top_jobs ?? []).slice(0, 10).map((j) => ({
    name: j.class.split('::').pop() ?? j.class,
    fullName: j.class,
    total: j.total,
    failed: j.failed,
  }));

  return (
    <div>
      <div className="section-header">
        <h1 className="page-title" style={{ margin: 0 }}>{t('nav.metrics')}</h1>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
          <span style={{ fontSize: 13, color: 'var(--text-muted)' }}>Last</span>
          <select
            className="select"
            value={minutes}
            onChange={(e) => setMinutes(Number(e.target.value))}
          >
            {MINUTE_OPTIONS.map((m) => (
              <option key={m} value={m}>
                {m >= 60 ? `${m / 60}h` : `${m}m`}
              </option>
            ))}
          </select>
        </div>
      </div>

      {isLoading && (
        <div className="empty-state"><span className="spinner" /></div>
      )}

      {isError && (
        <div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      )}

      {data && data.top_jobs.length === 0 && (
        <div className="empty-state">{t('common.empty')}</div>
      )}

      {data && data.top_jobs.length > 0 && (
        <>
          <div className="card" style={{ marginBottom: '1.5rem' }}>
            <div className="section-title" style={{ marginBottom: '1rem' }}>Top Jobs by Count</div>
            <ResponsiveContainer width="100%" height={280}>
              <BarChart data={chartData} margin={{ top: 4, right: 16, left: 0, bottom: 40 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis
                  dataKey="name"
                  tick={{ fill: 'var(--text-muted)', fontSize: 11 }}
                  angle={-35}
                  textAnchor="end"
                  interval={0}
                />
                <YAxis tick={{ fill: 'var(--text-muted)', fontSize: 11 }} />
                <Tooltip
                  contentStyle={{
                    background: 'var(--surface)',
                    border: '1px solid var(--border)',
                    color: 'var(--text)',
                    borderRadius: 6,
                    fontSize: 12,
                  }}
                  labelFormatter={(_: unknown, payload: unknown[]) => {
                    const item = payload?.[0] as { payload?: { fullName?: string } } | undefined;
                    return item?.payload?.fullName ?? '';
                  }}
                />
                <Bar dataKey="total" fill="var(--accent)" radius={[3, 3, 0, 0]} name="Total" />
                <Bar dataKey="failed" fill="var(--danger)" radius={[3, 3, 0, 0]} name="Failed" />
              </BarChart>
            </ResponsiveContainer>
          </div>

          <div className="table-wrapper">
            <table>
              <thead>
                <tr>
                  <th>{t('table.class')}</th>
                  <th>{t('table.total')}</th>
                  <th>Failed</th>
                  <th>Error Rate</th>
                  <th>Avg {t('common.ms')}</th>
                  <th>P99 {t('common.ms')}</th>
                </tr>
              </thead>
              <tbody>
                {data.top_jobs.map((job) => {
                  const errorRate = job.total > 0 ? (job.failed / job.total) * 100 : 0;
                  return (
                    <tr key={job.class}>
                      <td title={job.class} style={{ fontWeight: 500 }}>
                        {truncate(job.class, 50)}
                      </td>
                      <td style={{ fontVariantNumeric: 'tabular-nums' }}>{job.total.toLocaleString()}</td>
                      <td style={{ color: job.failed > 0 ? 'var(--danger)' : undefined, fontVariantNumeric: 'tabular-nums' }}>
                        {job.failed.toLocaleString()}
                      </td>
                      <td style={{ color: errorRate > 5 ? 'var(--danger)' : errorRate > 1 ? 'var(--warning)' : 'var(--success)' }}>
                        {errorRate.toFixed(1)}%
                      </td>
                      <td style={{ fontVariantNumeric: 'tabular-nums' }}>{job.avg_ms.toFixed(1)}</td>
                      <td style={{
                        fontVariantNumeric: 'tabular-nums',
                        color: job.p99_ms > 5000 ? 'var(--danger)' : job.p99_ms > 1000 ? 'var(--warning)' : undefined,
                      }}>
                        {job.p99_ms.toFixed(1)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
