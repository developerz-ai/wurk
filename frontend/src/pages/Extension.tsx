import { createSignal, createEffect, Show } from 'solid-js';
import { useParams } from '@solidjs/router';
import { PageHeader } from '../components/PageHeader';
import { Skeleton, SkeletonTable } from '../components/Skeleton';
import { useMeta } from '../hooks/useMeta';
import { basePath } from '../basePath';
import { t } from '../i18n';

// Renders a third-party extension tab registered via
// Sidekiq::Web.register_extension. When the tab maps to a registered extension
// (ext_name from /api/meta), its routes/ERB views are server-rendered by
// Wurk::Web::Extension::Renderer at <mount>/ext/<name>/* and embedded here
// natively — links and forms inside the view are intercepted so navigation
// stays on this page (#187). Tabs without an extension (bare `tabs[]=`
// mutation) keep the old iframe embed of their own path.
export default function Extension() {
  const params = useParams();
  const tab = () => params.tab ?? '';
  const meta = useMeta();
  // Registered index paths keep Sidekiq's trailing slash ("locks/") but the
  // route param never has one — compare them normalized.
  const norm = (p: string) => p.replace(/\/+$/, '');
  const entry = () => meta.data?.custom_tabs?.find((tab_) => norm(tab_.path) === norm(tab()));
  const name = () => entry()?.name ?? tab();

  return (
    <Show
      when={entry()?.ext_name}
      keyed
      fallback={<IframeExtension tab={tab()} title={name()} />}
    >
      {(extName) => <NativeExtension extName={extName} indexPath={tab()} title={name()} />}
    </Show>
  );
}

function NativeExtension(props: { extName: string; indexPath: string; title: string }) {
  const base = `${basePath()}/ext/${props.extName}/`;
  const [html, setHtml] = createSignal<string | null>(null);
  const [error, setError] = createSignal(false);
  // Monotonic request id: a response only lands if it's still the latest, so
  // rapid link clicks can't resolve out of order and show stale HTML.
  let seq = 0;

  const load = async (path: string, init?: RequestInit) => {
    const id = ++seq;
    try {
      const res = await fetch(base + path, init);
      const text = await res.text();
      if (id !== seq) return;
      setError(!res.ok && res.status !== 404);
      setHtml(text);
    } catch {
      if (id === seq) setError(true);
    }
  };

  createEffect(() => {
    void load(props.indexPath.replace(/\/+$/, ''));
  });

  // Keep extension-internal navigation inside this page: anchors and forms
  // whose target resolves under our embed base are fetched instead of
  // navigating the whole browser away from the SPA. Redirects (delete → list)
  // are followed by fetch transparently.
  const onClick = (e: MouseEvent) => {
    const a = (e.target as HTMLElement).closest('a');
    if (!a?.getAttribute('href')) return;
    const url = new URL(a.href, window.location.origin);
    if (url.origin !== window.location.origin || !url.pathname.startsWith(base)) return;
    e.preventDefault();
    void load(url.pathname.slice(base.length) + url.search);
  };

  const onSubmit = (e: Event) => {
    const form = e.target as HTMLFormElement;
    const url = new URL(form.getAttribute('action') || window.location.href, window.location.origin);
    if (url.origin !== window.location.origin || !url.pathname.startsWith(base)) return;
    e.preventDefault();
    const data = new FormData(form);
    if ((form.method || 'get').toUpperCase() === 'GET') {
      const qs = new URLSearchParams(Array.from(data.entries()) as [string, string][]).toString();
      void load(`${url.pathname.slice(base.length)}${qs ? `?${qs}` : ''}`);
    } else {
      void load(url.pathname.slice(base.length) + url.search, { method: 'POST', body: data });
    }
  };

  return (
    <>
      <PageHeader icon="fa-puzzle-piece" title={props.title} summary={t('extension.summary')} />
      <Show when={error()}>
        <div class="empty-state" style={{ color: 'var(--danger)' }}>{t('common.error')}</div>
      </Show>
      <Show when={html() === null && !error()}>
        <div class="skeleton-stack">
          <Skeleton height="1.5rem" width="40%" />
          <SkeletonTable rows={6} cols={4} />
        </div>
      </Show>
      <Show when={html() !== null && !error()}>
        <div
          class="card ext-view"
          onClick={onClick}
          onSubmit={onSubmit}
          // Extension HTML is rendered server-side from host-registered gem
          // code — the same trust model as Sidekiq::Web rendering it.
          innerHTML={html()!}
        />
      </Show>
    </>
  );
}

function IframeExtension(props: { tab: string; title: string }) {
  const src = () => `${basePath()}/${props.tab}?wurk_ext_embed=1`;
  return (
    <>
      <PageHeader icon="fa-puzzle-piece" title={props.title} summary={t('extension.summary')}>
        <a class="btn btn-sm" href={`${basePath()}/${props.tab}`} target="_blank" rel="noopener noreferrer">
          <i class="fa-solid fa-arrow-up-right-from-square" style={{ 'margin-inline-end': '0.4rem' }} />
          {t('extension.open')}
        </a>
      </PageHeader>

      <iframe
        title={props.title}
        src={src()}
        style={{
          width: '100%',
          height: 'calc(100vh - 11rem)',
          border: '1px solid var(--border)',
          'border-radius': 'var(--radius)',
          background: 'var(--surface)',
        }}
      />
    </>
  );
}
