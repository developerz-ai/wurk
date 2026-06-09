import { useParams } from 'react-router-dom';
import { PageHeader } from '../components/PageHeader';
import { useMeta } from '../hooks/useMeta';
import { t } from '../i18n';

// Renders a third-party extension tab registered via
// Sidekiq::Web.register_extension. wurk's dashboard is a precompiled React SPA
// with no server-side ERB render path, so we embed the extension's own path in
// an iframe (carrying ?wurk_ext_embed=1). If the host mounts the gem's Rack app
// there it renders; otherwise the SPA itself answers that path and main.tsx —
// seeing the embed flag inside an iframe — paints a small "not rendered" stub
// instead of recursively nesting the whole dashboard.
export default function Extension() {
  const { tab = '' } = useParams();
  const { data: meta } = useMeta();
  const name = meta?.custom_tabs?.find((tab_) => tab_.path === tab)?.name ?? tab;
  const src = `/wurk/${tab}?wurk_ext_embed=1`;

  return (
    <>
      <PageHeader icon="fa-puzzle-piece" title={name} summary={t('extension.summary')}>
        <a className="btn btn-sm" href={`/wurk/${tab}`} target="_blank" rel="noopener noreferrer">
          <i className="fa-solid fa-arrow-up-right-from-square" style={{ marginInlineEnd: '0.4rem' }} />
          {t('extension.open')}
        </a>
      </PageHeader>

      <iframe
        title={name}
        src={src}
        style={{
          width: '100%',
          height: 'calc(100vh - 11rem)',
          border: '1px solid var(--border)',
          borderRadius: 'var(--radius)',
          background: 'var(--surface)',
        }}
      />
    </>
  );
}
