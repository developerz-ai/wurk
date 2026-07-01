import { createSignal, For, type JSX } from 'solid-js';

interface VirtualListProps<T> {
  items: T[];
  rowHeight: number;
  visibleCount: number;
  renderItem: (item: T, i: number) => JSX.Element;
}

export function VirtualList<T>(props: VirtualListProps<T>) {
  const [scrollTop, setScrollTop] = createSignal(0);
  let containerRef!: HTMLDivElement;

  const containerHeight = () => props.rowHeight * props.visibleCount;
  const totalHeight = () => props.rowHeight * props.items.length;

  const startIndex = () => Math.floor(scrollTop() / props.rowHeight);
  const endIndex = () => Math.min(props.items.length - 1, startIndex() + props.visibleCount + 2);
  const paddingTop = () => startIndex() * props.rowHeight;
  const paddingBottom = () =>
    Math.max(0, totalHeight() - paddingTop() - (endIndex() - startIndex() + 1) * props.rowHeight);

  const visibleItems = () => props.items.slice(startIndex(), endIndex() + 1);

  const onScroll = () => {
    if (containerRef) {
      setScrollTop(containerRef.scrollTop);
    }
  };

  return (
    <div
      ref={containerRef}
      onScroll={onScroll}
      style={{
        height: `${containerHeight()}px`,
        'overflow-y': 'auto',
        'overflow-x': 'auto',
      }}
    >
      <div style={{ height: `${totalHeight()}px`, position: 'relative' }}>
        <div style={{ 'padding-top': `${paddingTop()}px`, 'padding-bottom': `${paddingBottom()}px` }}>
          <For each={visibleItems()}>
            {(item, i) => (
              <div style={{ height: `${props.rowHeight}px`, overflow: 'hidden' }}>
                {props.renderItem(item, startIndex() + i())}
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
