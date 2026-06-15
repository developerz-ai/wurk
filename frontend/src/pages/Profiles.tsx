import { useQuery } from '@tanstack/react-query';
import { useEffect } from 'react';
import { t } from '../i18n';

// One row from GET /wurk/api/profiles (Wurk::Api::Serializers.profile_record).
interface Profile {
  key: string;
  jid: string;
  token: string;
  type: string;
  size: number;
  elapsed: number;
  started_at: number | null;
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function fmtWhen(ts: number | null): string {
  return ts ? new Date(ts * 1000).toLocaleString() : '—';
}

export default function Profiles() {
  useEffect(() => {
    document.title = `${t('nav.profiles')} — Wurk`;
  }, []);

  const { data, isLoading, isError } = useQuery<Profile[]>({
    queryKey: ['profiles'],
    queryFn: async () => {
      const r = await fetch('/wurk/api/profiles');
      if (!r.ok) throw new Error(`profiles request failed: ${r.status}`);
      return r.json() as Promise<Profile[]>;
    },
    refetchInterval: 5000,
  });

  if (isLoading) return <div className="obs"><div className="empty-state"><span className="spinner" /></div></div>;
  // Guard against a non-array body slipping past isError — render the error
  // state rather than crashing on .length / .map.
  if (isError || !Array.isArray(data)) {
    return <div className="obs"><div className="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div></div>;
  }

  return (
    <div className="obs">
      <div className="obs-pagehead">
        <div>
          <h1>{t('nav.profiles')}</h1>
          <p className="obs-panel__sub">{t('summaries.profiles')}</p>
        </div>
        <span className="obs-chip obs-chip--active">{data.length.toLocaleString()}</span>
      </div>

      {data.length === 0 ? (
        <div className="obs-card obs-empty">{t('common.empty')}</div>
      ) : (
        <div className="obs-card obs-table">
          <div className="obs-tablescroll">
            <table>
              <thead>
                <tr>
                  <th>Type</th>
                  <th>JID</th>
                  <th>Started</th>
                  <th>Elapsed</th>
                  <th>Size</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {data.map((p) => (
                  <tr key={p.key}>
                    <td style={{ fontWeight: 500, color: 'var(--obs-text)' }}>{p.type}</td>
                    <td><span className="obs-mono-cell">{p.jid}</span></td>
                    <td>{fmtWhen(p.started_at)}</td>
                    <td>{p.elapsed.toLocaleString()} ms</td>
                    <td>{fmtBytes(p.size)}</td>
                    <td style={{ textAlign: 'end' }}>
                      {/* Full reload (not client-route): the backend POSTs the blob
                          to the Firefox profiler then 302s out to profiler.firefox.com. */}
                      <a
                        className="obs-btn obs-btn--ghost obs-btn--sm"
                        href={`/wurk/profiles/${encodeURIComponent(p.key)}`}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        <i className="fa-solid fa-up-right-from-square" aria-hidden="true" /> Open
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
