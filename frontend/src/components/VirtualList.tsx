import { useState, useRef, useCallback, type ReactNode } from 'react';

interface VirtualListProps<T> {
  items: T[];
  rowHeight: number;
  visibleCount: number;
  renderItem: (item: T, i: number) => ReactNode;
}

export function VirtualList<T>({ items, rowHeight, visibleCount, renderItem }: VirtualListProps<T>) {
  const [scrollTop, setScrollTop] = useState(0);
  const containerRef = useRef<HTMLDivElement>(null);

  const containerHeight = rowHeight * visibleCount;
  const totalHeight = rowHeight * items.length;

  const startIndex = Math.floor(scrollTop / rowHeight);
  const endIndex = Math.min(items.length - 1, startIndex + visibleCount + 2);
  const paddingTop = startIndex * rowHeight;
  const paddingBottom = Math.max(0, totalHeight - paddingTop - (endIndex - startIndex + 1) * rowHeight);

  const visibleItems = items.slice(startIndex, endIndex + 1);

  const onScroll = useCallback(() => {
    if (containerRef.current) {
      setScrollTop(containerRef.current.scrollTop);
    }
  }, []);

  return (
    <div
      ref={containerRef}
      onScroll={onScroll}
      style={{
        height: containerHeight,
        overflowY: 'auto',
        overflowX: 'auto',
      }}
    >
      <div style={{ height: totalHeight, position: 'relative' }}>
        <div style={{ paddingTop, paddingBottom }}>
          {visibleItems.map((item, i) => (
            <div key={startIndex + i} style={{ height: rowHeight, overflow: 'hidden' }}>
              {renderItem(item, startIndex + i)}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
